package Audit::DBI;

use strict;
use warnings;

use Carp;
use Data::Validate::Type;
use Storable;
use Try::Tiny;

use Audit::DBI::Event;
use Audit::DBI::Utils;


=head1 NAME

Audit::DBI - Audit data changes in your code and store searchable log records in a database.


=head1 VERSION

Version 1.4.1

=cut

our $VERSION = '1.4.1';


=head1 SYNOPSIS

	use Audit::DBI;
	
	# Create the audit object.
	my $audit = Audit::DBI->new(
		database_handle => $dbh,
	);
	
	# Create the necessary tables.
	$audit->create_tables();
	
	# Record an audit event.
	$audit->record(
		event               => $event,
		subject_type        => $subject_type,
		subject_id          => $subject_id,
		event_time          => $event_time,
		diff                => [ $old_structure, $new_structure ],
		search_data         => \%search_data,
		information         => \%information,
		affected_account_id => $account_id,
		file                => $file,
		line                => $line,
	);
	
	# Search audit events.
	my $audit_events = $audit->review(
		[ search criteria ]
	);


=head1 METHODS

=head2 new()

Create a new Audit::DBI object.

	my $audit = Audit::DBI->new(
		database_handle => $dbh,
	);

Parameters:

=over 4

=item * database handle

Mandatory, a DBI object.

=item * memcache

Optional, a Cache::Memcached or Cache::Memcached::Fast object to use for
rate limiting. If not specified, rate-limiting functions will not be available.

=back

=cut

sub new
{
	my ( $class, %args ) = @_;
	my $dbh = delete( $args{'database_handle'} );
	my $memcache = delete( $args{'memcache'} );
	croak 'The following arguments are not valid: ' . join( ', ', keys %args )
		if scalar( keys %args ) != 0;
	
	# Check parameters.
	croak "Argument 'database_handle' is mandatory and must be a DBI object"
		if !Data::Validate::Type::is_instance( $dbh, class => 'DBI::db' );

	my $self = bless(
		{
			'database_handle' => $dbh,
			'memcache'        => $memcache,
		},
		$class
	);

	return $self;
}


=head2 record()

Record an audit event along with information on the context and data changed.

	$audit->record(
		event               => $event,
		subject_type        => $subject_type,
		subject_id          => $subject_id,
		event_time          => $event_time,
		diff                => [ $old_structure, $new_structure ],
		search_data         => \%search_data,
		information         => \%information,
		affected_account_id => $account_id,
		file                => $file,
		line                => $line,
	);

Required:

=over 4

=item * event

The type of action performed (48 characters maximum).

=item * subject_type

Normally, the singular form of the name of a table, such as "object" or
"account" or "order".

=item * subject_id

If subject_type is a table, the corresponding record ID.

=back

Optional:

=over 4

=item * diff

This automatically calculates the differences between the two data structures
passed as values for this parameter, and makes a new structure recording those
differences.

=item * search_data

A hashref of all the key/value pairs that we may want to be able search on later
to find this type of event. You may pass either a scalar or an arrayref of
multiple values for each key.

=item * information

Any other useful information (such as user input) to understand the context of
this change.

=item * account_affected

The ID of the account to which the data affected during that event where linked
to, if applicable.

=item * event_time

Unix timestamp of the time that the event occurred, the default being the
current time.

=item * file and line

The filename and line number where the event occurred, the default being the
immediate caller of Audit::DBI->record().

=back

Note: if you want to delay the insertion of audit events (to group them, for
performance), subclass C<Audit::DBI> and add a custom C<insert_event()> method.

=cut

sub record ## no critic (NamingConventions::ProhibitAmbiguousNames)
{
	my( $self, %args ) = @_;
	my $limit_rate_timespan = delete( $args{'limit_rate_timespan'} );
	my $limit_rate_unique_key = delete( $args{'limit_rate_unique_key'} );
	my $dbh = $self->get_database_handle();
	
	# Check required parameters.
	foreach my $arg ( qw( event subject_type subject_id ) )
	{
		next if defined( $args{ $arg } ) && $args{ $arg } ne '';
		croak "The argument $arg must be specified.";
	}
	croak('The argument "limit_rate_timespan" must be a strictly positive integer.')
		if defined $limit_rate_timespan && ( $limit_rate_timespan !~ /^\d+$/ || $limit_rate_timespan == 0 );
	croak('The argument "limit_rate_unique_key" must be a string with length greater than zero.')
		if defined $limit_rate_unique_key && length $limit_rate_unique_key == 0;
	croak('Both "limit_rate_timespan" and "limit_rate_unique_key" must be defined.')
		if defined $limit_rate_timespan != defined $limit_rate_unique_key;
	
	# Rate limiting.
	if ( defined( $limit_rate_timespan ) )
	{
		if ( !defined( $self->get_cache( key => $limit_rate_unique_key ) ) )
		{
			# Cache event.
			$self->set_cache(
				key         => $limit_rate_unique_key,
				value       => 1,
				expire_time => time() + $limit_rate_timespan,
			);
		}
		else
		{
			# No need to log audit event.
			return 1;
		}
	}
	
	# Record the time (unless it was already passed in).
	$args{'event_time'} ||= time();
	
	# Store the file and line of the caller, unless they were passed in.
	if ( !defined( $args{'file'} ) || !defined( $args{'line'} ) )
	{
		my ( $file, $line ) = ( caller() )[1,2];
		$file =~ s|.*/||;
		$args{'file'} = $file
			if !defined( $args{'file'} );
		$args{'line'} = $line
			if !defined( $args{'line'} );
	}
	
	my $audit_event = $self->insert_event( \%args );
	
	return defined( $audit_event )
		? 1
		: 0;
}


=head2 review()

Return the logged audit events corresponding to the criteria passed as
parameter.

	my $results = $audit->review(
		ip_ranges   =>
		[
			{
				include => $boolean,
				begin   => $begin,
				end     => $end
			},
			...
		],
		subjects    =>
		[
			{
				include => $boolean,
				type    => $type1,
				ids     => \@id1,
			},
			{
				include => $boolean,
				type    => $type2,
				ids     => \@id2,
			},
			...
		],
		date_ranges =>
		[
			{
				include => $boolean,
				begin   => $begin,
				end     => $end
			},
			...
		],
		values      =>
		[
			{
				include => $boolean,
				name    => $name1,
				values  => \@value1,
			},
			{
				include => $boolean,
				name    => $name2,
				values  => \@value2,
			},
			...
		],
		events      =>
		[
			{
				include => $boolean,
				event   => $event,
			},
			...
		],
		logged_in   =>
		[
			{
				include    => $boolean,
				account_id => $account_id,
			},
			...
		],
		affected    =>
		[
			{
				include    => $boolean,
				account_id => $account_id,
			},
			...
		],
	);

All the parameters are optional, but at least one of them is required due to the
sheer volume of data this module tends to generate. If multiple parameters are
passed, they are additive, i.e. use AND to combine themselves.

=over 4

=item * ip_ranges

Allows restricting the search to ranges of IPs. Must be given in integer format.

=item * events

Allows searching on specific events.

=item * subjects

Allows to search on the subject types and subject IDs passed when calling
record(). Multiple subject types can be passed, and for each subject type
multiple IDs can be passed, hence the use of an arrayref of hashes for this
parameter. Using

	[
		{
			type => $type1,
			ids  => \@id1,
		},
		{
			type => $type2,
			ids  => \@id2,
		}
	]

would translate into

(subject_type = '[type1]' AND subject_id IN([ids1]) )
	OR (subject_type = '[type2]' AND subject_id IN([ids2]) )

for searching purposes.

=item * date_ranges

Allows restricting the search to specific date ranges.

=item * values

Searches on the key/values pairs initially passed via 'search_data' to record().

=item * logged_in

Searches on the ID of the account that was logged in at the time of the record()
call.

=item * affected

Searches on the ID of the account that was linked to the data that changed at
the time of the record() call.

=back

Optional parameters that are not search criteria:

=over 4

=item * database_handle

A specific database handle to use when searching for audit events. This allows
the use of a separate reader database for example, to do expensive search
queries. If this parameter is omitted, then the database handle specified when
calling new() is used.

=back

=cut

sub review ## no critic (Subroutines::ProhibitExcessComplexity)
{
	my ( $self, %args ) = @_;
	
	# Retrieve search parameters.
	my $subjects = delete( $args{'subjects'} );
	my $values = delete( $args{'values'} );
	my $ip_ranges = delete( $args{'ip_ranges'} );
	my $date_ranges = delete( $args{'date_ranges'} );
	my $events = delete( $args{'events'} );
	my $logged_in = delete( $args{'logged_in'} );
	my $affected = delete( $args{'affected'} );
	
	# Check remaining parameters.
	my $dbh = delete( $args{'database_handle'} );
	croak "Argument 'database_handle' must be a DBI object when defined"
		if defined( $dbh ) && !Data::Validate::Type::is_instance( $dbh, class => 'DBI::db' );
	croak 'Invalid argument(s): ' . join( ', ', keys %args )
		if scalar( keys %args ) != 0;
	
	### CLEAN PARAMETERS
	
	# Check that subjects are defined correctly.
	if ( defined( $subjects ) )
	{
		croak 'The parameter "subjects" must be an arrayref'
			if !Data::Validate::Type::is_arrayref( $subjects );
		
		foreach my $subject ( @$subjects )
		{
			croak 'The subject type must be defined'
				if !defined( $subject->{'type'} );
			
			croak 'The inclusion/exclusion flag must be defined'
				if !defined( $subject->{'include'} );
			
			croak 'If defined, the IDs for a given subject time must be in an array'
				if defined( $subject->{'ids'} ) && !Data::Validate::Type::is_arrayref( $subject->{'ids'} );
		}
	}
	
	# Check that values are defined correctly.
	if ( defined( $values ) )
	{
		croak 'The parameter "values" must be an arrayref'
			if !Data::Validate::Type::is_arrayref( $values );
		
		foreach my $value ( @$values )
		{
			croak 'The name must be defined'
				if !defined( $value->{'name'} );
			
			croak 'The inclusion/exclusion flag must be defined'
				if !defined( $value->{'include'} );
			
			croak 'The values for a given name must be in an arrayref'
				if !defined( $value->{'values'} ) || !Data::Validate::Type::is_arrayref( $value->{'values'} );
		}
	}
	
	# Check that the IP ranges are defined correctly
	if ( defined( $ip_ranges ) )
	{
		croak 'The parameter "ip_ranges" must be an arrayref'
			if !Data::Validate::Type::is_arrayref( $ip_ranges );
		
		foreach my $ip_range ( @$ip_ranges )
		{
			croak 'The inclusion/exclusion flag must be defined'
				if !defined( $ip_range->{'include'} );
			
			croak 'The lower bound of the IP range must be defined'
				if !defined( $ip_range->{'begin'} );
			
			croak 'The higher bound of the IP range must be defined'
				if !defined( $ip_range->{'end'} );
		}
	}
	
	# Check that the date range is defined correctly
	if ( defined( $date_ranges ) )
	{
		croak 'The parameter "date_ranges" must be an arrayref'
			if !Data::Validate::Type::is_arrayref( $date_ranges );
		
		foreach my $date_range ( @$date_ranges )
		{
			croak 'The inclusion/exclusion flag must be defined'
				if !defined( $date_range->{'include'} );
			
			croak 'The lower bound of the date range must be defined'
				if !defined( $date_range->{'begin'} );
			
			croak 'The higher bound of the date range must be defined'
				if !defined( $date_range->{'end'} );
		}
	}
	
	### PREPARE THE QUERY
	my @clause = ();
	my @join = ();
	$dbh = $self->get_database_handle()
		if !defined( $dbh );
	
	# Filter by IP range.
	if ( defined( $ip_ranges ) )
	{
		my @or_clause = ();
		foreach my $ip_range ( @$ip_ranges )
		{
			my $begin = $dbh->quote( $ip_range->{'begin'} );
			my $end = $dbh->quote( $ip_range->{'end'} );
			my $clause = "((ipv4_address >= $begin) AND (ipv4_address <= $end))";
			
			$clause = "(NOT $clause)"
				if !$ip_range->{'include'};
			
			push( @or_clause, $clause );
		}
		
		push( @clause, '(' . join( ') OR (', @or_clause ) . ')' )
			if scalar( @or_clause ) != 0;
	}
	
	# Filter by subject_type and subject_id.
	if ( defined( $subjects ) )
	{
		my @or_clause = ();
		foreach my $subject ( @$subjects )
		{
			my $clause = '(subject_type = ' . $dbh->quote( $subject->{'type'} ) . ')';

			$clause = "($clause AND (subject_id IN (" . join( ',', map { $dbh->quote( $_ ) } @{ $subject->{'ids'} } ) . ')))'
				if defined( $subject->{'ids'} ) && ( scalar( @{ $subject->{'ids'} } ) != 0 );
			
			$clause = "(NOT $clause)"
				if !$subject->{'include'};
			
			push( @or_clause, $clause );
		}
		
		push( @clause, '(' . join( ') OR (', @or_clause ) . ')' )
			if scalar( @or_clause ) != 0;
	}
	
	# Filter using the manually set key/value pairs.
	if ( defined( $values ) )
	{
		my @or_clause = ();
		foreach my $value ( @$values )
		{
			my $clause = '(name = ' . $dbh->quote( lc( $value->{'name'} ) ) . ')';
			
			$clause = "($clause AND (value IN (" . join( ',', map { $dbh->quote( lc( $value ) ) } @{ $value->{'values'} } ) . ')))'
				if defined( $value->{'values'} ) && ( scalar( @{ $value->{'values'} } ) != 0 );
			
			$clause = "(NOT $clause)"
				if !$value->{'include'};
			
			push( @or_clause, $clause );
		}
		
		if ( scalar( @or_clause ) != 0 )
		{
			push( @join, 'LEFT JOIN audit_search USING(audit_event_id)' );
			push( @clause, '(' . join( ') OR (', @or_clause ) . ')' );
		}
	}
	
	# Filter by date range.
	if ( defined( $date_ranges ) )
	{
		my @or_clause = ();
		foreach my $date_range ( @$date_ranges )
		{
			my $begin = $dbh->quote( $date_range->{'begin'} );
			my $end = $dbh->quote( $date_range->{'end'} );
			my $clause = "((event_time >= $begin) AND (event_time <= $end))";
			
			$clause = "(NOT $clause)"
				if !$date_range->{'include'};
			
			push( @or_clause, $clause );
		}
		
		push( @clause, '(' . join( ') OR (', @or_clause ) . ')' )
			if scalar( @or_clause ) != 0;
	}
	
	# Filter using events.
	if ( defined( $events ) )
	{
		my @or_clause = ();
		foreach my $data ( @$events )
		{
			my $event = $dbh->quote( $data->{'event'} );
			my $operand = ( $data->{'include'} ? '=' : '!=' );
			push( @or_clause, "( event $operand $event)" );
		}
		
		push( @clause, '(' . join( ') OR (', @or_clause ) . ')' )
			if scalar( @or_clause ) != 0;
	}
	
	# Filter using account IDs.
	if ( defined( $logged_in ) )
	{
		my @or_clause = ();
		foreach my $data ( @$logged_in )
		{
			my $account_id = $dbh->quote( $data->{'account_id'} );
			my $operand = ( $data->{'include'} ? '=' : '!=' );
			push( @or_clause, "( logged_in_account_id $operand $account_id)" );
		}
		
		push( @clause, '(' . join( ') OR (', @or_clause ) . ')' )
			if scalar( @or_clause ) != 0;
	}
	if ( defined( $affected ) )
	{
		my @or_clause = ();
		foreach my $data ( @$affected )
		{
			my $account_id = $dbh->quote( $data->{'account_id'} );
			my $operand = ( $data->{'include'} ? '=' : '!=' );
			push( @or_clause, "( affected_account_id $operand $account_id)" );
		}
		
		push( @clause, '(' . join( ') OR (', @or_clause ) . ')' )
			if scalar( @or_clause ) != 0;
	}
	
	# Make sure we have at least one criteria, else something went wrong when we
	# checked the parameters.
	croak 'No filtering criteria was created, cannot search'
		if scalar( @clause ) == 0;
	
	# Query the database.
	my $joins = join( "\n", @join );
	my $where = '(' . join( ') AND (', @clause ) . ')';
	my $query = qq|
		SELECT DISTINCT audit_events.*
		FROM audit_events
		$joins
		WHERE $where
		ORDER BY created ASC
	|;
	
	my $events_handle = $dbh->prepare( $query );
	$events_handle->execute();
	
	my $results = [];
	while ( my $result = $events_handle->fetchrow_hashref() )
	{
		push(
			@$results,
			Audit::DBI::Event->new( data => $result ),
		);
	}
	
	return $results;
}


=head2 create_tables()

Create the tables required to store audit events.

	$audit->create_tables(
		drop_if_exist => $boolean,      #default 0
		database_type => $database_type #default SQLite
	);

=cut

sub create_tables
{
	my ( $self, %args ) = @_;
	my $drop_if_exist = delete( $args{'drop_if_exist'} );
	croak 'Invalid argument(s): ' . join( ', ', keys %args )
		if scalar( keys %args ) != 0;
	
	# Defaults.
	$drop_if_exist = 0
		unless defined( $drop_if_exist ) && $drop_if_exist;
	
	# Check database type.
	my $database_handle = $self->get_database_handle();
	my $database_type = $database_handle->{'Driver'}->{'Name'};
	croak 'This database type is not supported yet. Please email the maintainer of the module for help.'
		if $database_type !~ m/^(?:SQLite|MySQL)$/;
	
	# Create the table that will hold the audit records.
	$database_handle->do( q|DROP TABLE IF EXISTS audit_events| )
		if $drop_if_exist;
	$database_handle->do(
		$database_type eq 'SQLite'
			? q|
				CREATE TABLE audit_events (
					audit_event_id INTEGER PRIMARY KEY AUTOINCREMENT,
					logged_in_account_id varchar(48) default NULL,
					affected_account_id varchar(48) default NULL,
					event varchar(48) default NULL,
					event_time int(10) default NULL,
					subject_type varchar(48) default NULL,
					subject_id varchar(255) default NULL,
					diff text,
					information text,
					ipv4_address int(10) default NULL,
					created int(10) NOT NULL,
					file varchar(32) NOT NULL default '',
					line smallint(5) NOT NULL default '0'
				)
			|
			: q|
				CREATE TABLE audit_events (
					audit_event_id int(10) unsigned NOT NULL auto_increment,
					logged_in_account_id varchar(48) default NULL,
					affected_account_id varchar(48) default NULL,
					event varchar(48) default NULL,
					event_time int(10) unsigned default NULL,
					subject_type varchar(48) default NULL,
					subject_id varchar(255) default NULL,
					diff text,
					information text,
					ipv4_address int(10) unsigned default NULL,
					created int(10) unsigned NOT NULL,
					file varchar(32) NOT NULL default '',
					line smallint(5) unsigned NOT NULL default '0',
					PRIMARY KEY  (audit_event_id),
					KEY idx_event (event),
					KEY idx_event_time (event_time),
					KEY idx_ip_address (ip_address),
					KEY idx_file_line (file,line),
					KEY idx_logged_in_account_id (logged_in_account_id(8)),
					KEY idx_affected_account_id (affected_account_id(8)),
					KEY idx_subject (subject_type(6),subject_id(12))
				)
				ENGINE=InnoDB
			|
	);

	# Create the table that will hold the audit search index.
	$database_handle->do( q|DROP TABLE IF EXISTS audit_search| )
		if $drop_if_exist;
	$database_handle->do(
		$database_type eq 'SQLite'
			? q|
				CREATE TABLE audit_search (
					audit_search_id INTEGER PRIMARY KEY AUTOINCREMENT,
					audit_event_id int(10) NOT NULL,
					name varchar(48) default NULL,
					value varchar(255) default NULL
				)
			|
			: q|
				CREATE TABLE audit_search (
					audit_search_id int(10) unsigned NOT NULL auto_increment,
					audit_event_id int(10) unsigned NOT NULL,
					name varchar(48) default NULL,
					value varchar(255) default NULL,
					PRIMARY KEY  (audit_search_id),
					KEY idx_name (name),
					KEY idx_value (value),
					CONSTRAINT audit_event_id_ibfk_1 FOREIGN KEY (audit_event_id) REFERENCES audit_events (audit_event_id)
				)
				ENGINE=InnoDB
			|
	);

	return;
}


=head1 ACCESSORS

=head2 get_database_handle()

Return the database handle tied to the audit object.

	my $database_handle = $audit->_get_database_handle();

=cut

sub get_database_handle
{
	my ( $self ) = @_;

	return $self->{'database_handle'};
}


=head2 get_memcache()

Return the database handle tied to the audit object.

	my $memcache = $audit->get_memcache();

=cut

sub get_memcache
{
	my ( $self ) = @_;

	return $self->{'memcache'};
}


=head1 INTERNAL METHODS

=head2 get_cache()

Get a value from the cache.

	my $value = $audit->get_cache( key => $key );

=cut

sub get_cache
{
	my ( $self, %args ) = @_;
	my $key = delete( $args{'key'} );
	croak 'Invalid argument(s): ' . join( ', ', keys %args )
		if scalar( keys %args ) != 0;
	
	# Check parameters.
	croak 'The parameter "key" is mandatory'
		if !defined( $key ) || $key !~ /\w/;
	
	my $memcache = $self->get_memcache();
	return undef
		if !defined( $memcache );
	
	return $memcache->get( $key );
}


=head2 set_cache()

Set a value into the cache.

	$audit->set_cache(
		key         => $key,
		value       => $value,
		expire_time => $expire_time,
	);

=cut

sub set_cache
{
	my ( $self, %args ) = @_;
	my $key = delete( $args{'key'} );
	my $value = delete( $args{'value'} );
	my $expire_time = delete( $args{'expire_time'} );
	croak 'Invalid argument(s): ' . join( ', ', keys %args )
		if scalar( keys %args ) != 0;
	
	# Check parameters.
	croak 'The parameter "key" is mandatory'
		if !defined( $key ) || $key !~ /\w/;
	
	my $memcache = $self->get_memcache();
	return
		if !defined( $memcache );
	
	$memcache->set( $key, $value, $expire_time )
		|| carp 'Failed to set cache with key >' . $key . '<';
	
	return;
}


=head2 insert_event()

Insert an audit event in the database.

	my $audit_event = $audit->insert_event( \%data );

Important: note that this is an internal function that record() calls. You should
be using record() instead. What you can do with this function is to subclass
it if you need to extend/change how events are inserted, for example:

=over 4

=item

if you want to stash it into a register_cleanup() when you're making the
all in Apache context (so that audit calls don't slow down the main request);

=item

if you want to insert extra information.

=back

=cut

sub insert_event
{
	my ( $self, $data ) = @_;
	my $dbh = $self->get_database_handle();
	
	return try
	{
		# Make a diff if applicable based on the content of 'diff'
		if ( defined( $data->{'diff'} ) )
		{
			croak 'The "diff" argument must be an arrayref'
				if !Data::Validate::Type::is_arrayref( $data->{'diff'} );
			
			croak 'The "diff" argument cannot have more than two elements'
				if scalar( @{ $data->{'diff'} } ) > 2;
			
			$data->{'diff'} = MIME::Base64::encode_base64(
				Storable::freeze(
					Audit::DBI::Utils::diff_structures( @{ $data->{'diff'} } )
				)
			);
		}
		
		# Clean input.
		my $search_data = delete( $data->{'search_data'} );
		
		# Freeze the free-form data as soon as it is set on the object, in case it's
		# a complex data structure with references that may be updated before the
		# insert in the database.
		$data->{'information'} = MIME::Base64::encode_base64( Storable::freeze( $data->{'information'} ) )
			if defined( $data->{'information'} );
		
		# Set defaults.
		$data->{'created'} = time();
		$data->{'ipv4_address'} = Audit::DBI::Utils::ipv4_to_integer( $ENV{'REMOTE_ADDR'} );
		$data->{'event_time'} = time()
			if !defined( $data->{'event_time'} );
		
		# Insert.
		my @fields = ();
		my @values = ();
		foreach my $field ( keys %$data )
		{
			push( @fields, $dbh->quote( $field) );
			push( @values, $data->{ $field } );
		}
		my $insert = $dbh->do(
			sprintf(
				q|
					INSERT INTO audit_events( %s )
					VALUES ( %s )
				|,
				join( ', ', @fields ),
				join( ', ', ( '?' ) x scalar( @fields ) ),
			),
			{},
			@values,
		) || croak 'Cannot execute SQL: ' . $dbh->errstr();
		$data->{'audit_event_id'} = $dbh->last_insert_id(
			undef,
			undef,
			'audit_events',
			'audit_event_id',
		);
		
		# Create an object to return.
		my $audit_event = Audit::DBI::Event->new( data => $data );
		
		# Add the search data
		if ( defined( $search_data ) )
		{
			my $sth = $dbh->prepare(
				q|
					INSERT INTO audit_search( audit_event_id, name, value )
					VALUES( ?, ?, ? )
				|
			);
			
			foreach my $name ( keys %$search_data )
			{
				my $values = $search_data->{ $name };
				$values = [ $values ] # Force array
					if !Data::Validate::Type::is_arrayref( $values );
				
				foreach my $value ( @$values )
				{
					$sth->execute(
						$data->{'audit_event_id'},
						lc( $name ),
						lc( $value || '' ),
					) || carp 'Failed to insert search index key >' . $name . '< for audit event ID >' . $audit_event->get_id() . '<';
				}
			}
		}
		
		return $audit_event;
	}
	catch
	{
		carp $_;
		return undef;
	};
}


=head1 AUTHOR

Guillaume Aubert, C<< <aubertg at cpan.org> >>.


=head1 BUGS

Please report any bugs or feature requests to C<bug-audit-dbi at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Audit-DBI>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.


=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc Audit::DBI


You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=Audit-DBI>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/Audit-DBI>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/Audit-DBI>

=item * Search CPAN

L<http://search.cpan.org/dist/Audit-DBI/>

=back


=head1 ACKNOWLEDGEMENTS

Thanks to ThinkGeek (L<http://www.thinkgeek.com/>) and its corporate overlords
at Geeknet (L<http://www.geek.net/>), for footing the bill while I write code
for them!

Thanks to Nathan Gray (KOLIBRIE) for implementing rate limiting in record()
calls in v1.3.0.


=head1 COPYRIGHT & LICENSE

Copyright 2012 Guillaume Aubert.

This program is free software; you can redistribute it and/or modify it
under the terms of the Artistic License.

See http://dev.perl.org/licenses/ for more information.

=cut

1;
