package Module::Build::DB;

use strict;
use warnings;

use base 'Module::Build';
our $VERSION = '0.10';

=begin comment

Fake-out Module::Build. Delete if it ever changes to support =head1 headers
other than all uppercase.

=head1 NAME

Module::Build::DB - Build and test database-backed applications

=end comment

=head1 Name

Module::Build::DB - Build and test database-backed applications

=head1 Synopsis

In F<Build.PL>:

  use strict;
  use lib 'lib';
  use Module::Build::DB;

  Module::Build::DB->new(
      module_name => 'MyApp',
  )->create_build_script;

=head1 Description

This module subclasses L<Module::Build|Module::Build> to provide added
functionality for installing and testing database-backed applications.

=cut

##############################################################################

=head1 Class Interface

=head2 Properties

Module::Build::DB defines these properties in addition to those specified by
L<Module::Build|Module::Build>. Note that these may be specified either in
F<Build.PL> or on the command-line.

=head3 context

  perl Build.PL --context test

Specifies the context in which the build will run. The context associates the
build with a configuration file, and therefore must be named for one of the
configuration files in F<conf>. For example, to build in the "dev" context,
there must be a F<conf/dev.yml> file. Defaults to "test", which is also the
only required context.

=head3 db_config_key

The YAML key under which DBI configuration is stored in the configuration
files. Defaults to "dbi". The keys that should be under this configuration
key are:

=over

=item * C<dsn>

=item * C<user>

=item * C<pass>

=back

=head3 db_client

  perl Build.PL --db_client /usr/local/pgsql/bin/pgsql

Specifies the location of the database command-line client. Defaults to
F<psql>, F<mysql>, or F<sqlite3>, depending on the value of the DSN in the
context configuration file.

=head3 drop_db

  ./Build db --drop_db 1

Tells the L</"db"> action to drop the database and build a new one. When this
property is set to a false value (the default), an existing database for the
current context will not be dropped, but it will be brought up-to-date.

=head3 test_env

  ./Build db --test_env CATALYST_DEBUG=0 CATALYST_CONFIG=conf/test.yml

Optional hash reference of environment variables to set for the lifetime of
C<./Build test>. This can be useful for making Catalyst less verbose, for
example. Another use is to tell PostgreSQL where to find pgTAP functions when
they're installed in a schema outside the normal search path in your database:

  ./Build db --test_env PGOPTIONS='--search_path=tap,public'

=cut

__PACKAGE__->add_property( context          => 'test' );
__PACKAGE__->add_property( cx_config        => undef  );
__PACKAGE__->add_property( db_config_key    => 'dbi'  );
__PACKAGE__->add_property( db_client        => undef  );
__PACKAGE__->add_property( drop_db          => 0      );
__PACKAGE__->add_property( db_test_cmd      => undef  );
__PACKAGE__->add_property( test_env         => {}     );

##############################################################################

=head2 Actions

=head3 test

=begin comment

=head3 ACTION_test

=end comment

Overrides the default implementation to ensure that tests are only run in the
"test" context, to make sure that the database is up-to-date, and to set up
the test environment with values stored in C<test_env>.

=cut

sub ACTION_test {
    my $self = shift;
    die qq{ERROR: Tests can only be run in the "test" context\n}
        . "Try `./Build test --context test`\n"
        unless $self->context eq 'test';

    # Make sure the database is up-to-date.
    $self->depends_on('code');

    # Set things up for pgTAP tests.
    my $config = $self->read_cx_config;
    my ( $db, $cmd ) = $self->db_cmd( $config->{$self->db_config_key} );
    $self->db_test_cmd([ @$cmd, $self->{driver}->get_db_option($db) ]);

    # Tell the tests where to find stuff, like pgTAP.
    local %ENV = ( %ENV, %{ $self->test_env } );

    # Make it so.
    $self->SUPER::ACTION_test(@_);
}

=begin comment

=head3 run_tap_harness

Override to properly C<exit 1> on failure, until a new version comes out with
this patch: L<http://rt.cpan.org/Public/Bug/Display.html?id=49080> (probably
0.36).

=end comment

=cut

sub run_tap_harness {
    my $ret = shift->SUPER::run_tap_harness(@_);
    exit 1 if $ret->{failed};
    return $ret;
}

##############################################################################

=head3 config_data

=begin comment

=head3 ACTION_config_data

XXX There needs to be a better way to do this (noted in To-Dos, too).

=end comment

Overrides the default implementation to completely change its behavior. :-)
Rather than creating a whole new configuration file in Module::Build's weird
way, this action now simply opens the application file (that returned by
C<dist_version_from> and replaces all instances of "conf/dev.yml" with the
configuration file for the current context. This means that an installed app
is effectively configured for the proper context at installation time.

=cut

sub ACTION_config_data {
    my $self = shift;

    my $file = File::Spec->catfile( split qr{/}, $self->dist_version_from);
    my $blib = File::Spec->catfile( $self->blib, $file );

    # Die if there is no file
    die qq{ERROR: "$blib" seems to be missing!\n} unless -e $blib;

    # Just return if the default is correct.
    return $self if $self->context eq 'dev';

    # Figure out where we're going to install this beast.
    $file       .= '.new';
    my $new     = File::Spec->catfile( $self->blib, $file );
    my $config  = $self->cx_config;
    my $default = quotemeta File::Spec->catfile( qw( conf dev.yml) );

    # Update the file.
    open my $orig, '<', $blib or die qq{Cannot open "$blib": $!\n};
    open my $temp, '>', $new or die qq{Cannot open "$new": $!\n};
    while (<$orig>) {
        s/$default/$config/g;
        print $temp $_;
    }
    close $orig;
    close $temp;

    # Make the switch.
    rename $new, $blib or die "Cannot rename '$blib' to '$new': $!\n";
    return $self;
}

##############################################################################

=head3 db

=begin comment

=head3 ACTION_db

=end comment

This action creates or updates the database for the current context. If
C<drop_db> is set to a true value, the database will be dropped and created
anew. Otherwise, if the database already exists, it will be brought up-to-date
from the files in the F<sql> directory.

Those files are expected to all be SQL scripts. They must all start with a
number followed by a dash. The number indicates the order in which the scripts
should be run. For example, you might have SQL files like so:

  sql/001-types.sql
  sql/002-tables.sql
  sql/003-triggers.sql
  sql/004-functions.sql
  sql/005-indexes.sql

The SQL files will be run in order to build or update the database.
Module::Build::DB will track the current schema update number corresponding to
the last run SQL script in the C<metadata> table in the database.

If any of the scripts has an error, Module::Build::DB will immediately exit with
the relevant error. To prevent half-way applied updates, the SQL scripts
should use transactions as appropriate.

=cut

sub ACTION_db {
    my $self = shift;

    # Get the database configuration information.
    my $config = $self->read_cx_config;

    my ( $db, $cmd ) = $self->db_cmd( $config->{$self->db_config_key} );

    # Does the database exist?
    my $db_exists = $self->drop_db ? 1 : $self->_probe(
        $self->{driver}->get_check_db_command($cmd, $db)
    );

    if ( $db_exists ) {
        # Drop the existing database?
        if ( $self->drop_db ) {
            $self->log_info(qq{Dropping the "$db" database\n});
            $self->do_system(
                $self->{driver}->get_drop_db_command($cmd, $db)
            ) or die;
        } else {
            # Just run the upgrades and be done with it.
            $self->upgrade_db( $db, $cmd );
            return;
        }
    }

    # Now create the database and run all of the SQL files.
    $self->log_info(qq{Creating the "$db" database\n});
    $self->do_system( $self->{driver}->get_create_db_command($cmd, $db) ) or die;

    # Add the metadata table and run all of the schema scripts.
    $self->create_meta_table( $db, $cmd );
    $self->upgrade_db( $db, $cmd );
}

##############################################################################

=head2 Instance Methods

=begin private

=head3 cx_config

Stores the current context's configuration file. Private for now.

=end private

=cut

sub cx_config {
    my $self = shift;
    return $self->{properties}{cx_config} if $self->{properties}{cx_config};
    return $self->{properties}{cx_config} = File::Spec->catfile(
        'conf',
        $self->context . '.yml',
    );
}

##############################################################################

=head3 read_cx_config

  my $config = $build->read_cx_config;

Uses L<YAML::Syck|YAML::Syck> to read and return the contents of the current
context's configuration file. Private for now.

=cut

sub read_cx_config {
    my $self = shift;
    my $cfile = $self->cx_config;
    die qq{Cannot read configuration file "$cfile" because it does not exist\n}
        unless -f $cfile;
    require YAML::Syck;
    YAML::Syck::LoadFile($cfile);
}

=begin private

=head3 db_cmd

  my ($db_name, $db_cmd) = $build->db_cmd;

Uses the current context's configuration to determine all of the options to
run the C<db_client> both for testing and for building the database. Returns
the name of the database and an array ref representing the C<db_client>
command and all of its options, suitable for passing to C<system>. The
database name is not included so as to enable connecting to another database
(e.g., template1 on PostgreSQL) to create the database.

=cut

sub db_cmd {
    my ($self, $dconf) = @_;

    return @{$self}{qw(db_name db_cmd)} if $self->{db_cmd} && $self->{db_name};

    require DBI;
    my (undef, $driver, undef, undef, $driver_dsn) = DBI->parse_dsn($dconf->{dsn});
    my %dsn = map { split /=/ } split /;/, $driver_dsn;

    $driver = __PACKAGE__ . "::$driver";
    eval "require $driver"
        or die $@ || "Package $driver did not return a true value\n";

    # Make sure we have a client.
    $self->db_client( $driver->get_client ) unless $self->db_client;

    my ($db, $cmd) = $driver->get_db_and_command($self->db_client, {
        %{ $dconf }, %dsn
    });
    $self->{db_cmd} = $cmd;
    $self->{db_name} = $db;
    $self->{driver} = $driver;
    return ($db, $cmd);
}

##############################################################################

=head3 create_meta_table

  my ($db_name, $db_cmd ) = $build->db_cmd;
  $build->create_meta_table( $db_name, $db_cmd );

Creates the C<metadata> table, which Module::Build::DB uses to track the current
schema version (corresponding to update numbers on the SQL scripts in F<sql>
and other application metadata. If the table already exists, it will be
dropped and recreated. One row is initially inserted, setting the
"schema_version" to 0.

=cut

sub create_meta_table {
    my ($self, $db, $cmd) = @_;
    my $quiet = $self->quiet;
    $self->quiet(1) unless $quiet;
    my $driver = $self->{driver};
    $self->do_system($driver->get_execute_command(
        $cmd, $db,
        $driver->get_metadata_table_sql,
    )) or die;
    $self->do_system( $driver->get_execute_command($cmd, $db, q{
        INSERT INTO metadata VALUES ( 'schema_version', 0, '' );
    })) or die;
    $self->quiet(0) unless $quiet;
}

##############################################################################

=head3 upgrade_db

  my ($db_name, $db_cmd ) = $build->db_cmd;
  push $db_cmd, '--dbname', $db_name;
  $self->upgrade_db( $db_name, $db_cmd );

Upgrades the database using all of the schema files in the F<sql> directory,
applying each in numeric order, setting the schema version upon the success of
each, and exiting upon any error.

=cut

sub upgrade_db {
    my ($self, $db, $cmd) = @_;

    $self->log_info(qq{Updating the "$db" database\n});
    my $driver = $self->{driver};

    # Get the current version number of the schema.
    my $curr_version = $self->_probe(
        $driver->get_execute_command(
            $cmd, $db,
            qq{SELECT value FROM metadata WHERE label = 'schema_version'},
        )
    );

    my $quiet = $self->quiet;
    # Apply all relevant upgrade files.
    for my $sql (sort grep { -f } glob 'sql/[0-9]*-*.sql' ) {
        # Compare upgrade version numbers.
        ( my $new_version = $sql ) =~ s{^sql[/\\](\d+)-.+}{$1};
        next unless $new_version > $curr_version;

        # Apply the version.
        $self->do_system( $driver->get_file_command($cmd, $db, $sql) ) or die;
        $self->quiet(1) unless $quiet;
        $self->do_system( $driver->get_execute_command($cmd, $db, qq{
            UPDATE metadata
               SET value = $new_version
             WHERE label = 'schema_version'
        })) or die;
        $self->quiet(0) unless $quiet;
    }
}

sub _probe {
    my $self = shift;
    my $ret = $self->_backticks(@_);
    chomp $ret;
    return $ret;
}

1;

__END__

=head1 To Do

=over

=item *

Improve migration support to be smarter? See
L<http://www.justatheory.com/computers/databases/change-management.html>.

=item *

Allow (some) tests to run without requiring C<./Build db>?

=item *

Be more flexible about how to set the default configuration file? Right now
C<ACTION_config_data()> modifies the C<dist_version_from()> file. There needs
to be a better way.

=item *

Support config files formats other than YAML. Maybe just switch to JSON and be
done with it?

=back

=head1 Author

=begin comment

Fake-out Module::Build. Delete if it ever changes to support =head1 headers
other than all uppercase.

=head1 AUTHORS

=end comment

David E. Wheeler <david@justatheory.com>

=head1 Copyright

Copyright (c) 2008-2009 David E. Wheeler. Some Rights Reserved.

This module is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.
