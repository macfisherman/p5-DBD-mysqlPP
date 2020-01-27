# This test uses docker to start a MySQL instance
# in such a way is it should not interfere with
# existing setups. At the beginning of the test
# it is normal to see timeouts while trying to
# connect to the database.
#
# Copyright (C) 2020 Jeff Macdonald <macfisherman@gmail.com>
#

use Test::More;

use DBI;

use Data::Dumper;

use strict;

SKIP: {
    my $docker = `which docker`;
    skip "docker not installed", 1 unless $docker;

    # Remove existing setup if test has bailed out before cleaning up.
    cleanup_docker();

    # Run an instance and get random port selected by docker.
    my $mysql_opts = "-e MYSQL_ROOT_PASSWORD=password -e MYSQL_DATABASE=test";
    `docker run -P --name mysqlPP-test $mysql_opts -d mysql:8 --default-authentication-plugin=mysql_native_password`;
    my $port = get_port();

    # Wait for docker and then initialize the db.
    my $dbh = wait_till_up($port);
    initialize_db($dbh);

    # The next two statements make for a cleaner test and have nothing
    # to do with the problem.
    $dbh->{RaiseError} = 1;
    $dbh->{PrintError} = 0;

    # begin_work failed before fix, so catch it.
    eval {
        $dbh->begin_work();
    };
    unlike($@, qr/Can't disable AutoCommit/, "AutoCommit disabled");

    # do a rollback
    $dbh->do(qq{
            insert into test
            (id, name)
            values
            (2, 'bob');
    });

    $dbh->rollback();

    # ensure new row was not committed
    my @rows = $dbh->selectall_array(qq{select id, name from test});
    is_deeply(\@rows, [[1, 'alice']], "rollback worked");

    # previous rollback should of re-enabeld AutoCommit
    # do another insert that should be autocommitted
    $dbh->do(qq{
            insert into test
            (id, name)
            values
            (2, 'bob');
    });

    # check for new row
    @rows = $dbh->selectall_array(qq{select id, name from test order by id});
    is_deeply(\@rows, [[1, 'alice'],[2, 'bob']], "autocommitted");

    # try an explicate commit
    $dbh->begin_work();
    $dbh->do(qq{
            insert into test
            (id, name)
            values
            (3, 'mary');
    });
    $dbh->commit();

    # check for new row
    @rows = $dbh->selectall_array(qq{select id, name from test order by id});
    is_deeply(\@rows, [[1, 'alice'],[2, 'bob'],[3, 'mary']], "committed");

    unless($ENV{SKIP_CLEANUP}) {
        cleanup_docker();
    }
}

done_testing();

sub cleanup_docker {
    note("cleaning docker");
    `docker stop mysqlPP-test`;
    `docker rm mysqlPP-test`;
}

sub initialize_db {
    my $dbh = shift;

    $dbh->do(qq{
        create table test (
            id integer,
            name varchar(20)
        );
    });

    $dbh->do(qq{
        insert into test
        (id, name)
        values
        (1, 'alice');
    });
}

sub get_port {
    my $ip_port = `docker port mysqlPP-test 3306`;
    chomp $ip_port;
    my ($ip,$port) = split(/:/, $ip_port);
    return $port;
}

sub wait_till_up {
        my $port = shift;

        my $dbh;
        my $dsn = "dbi:mysqlPP:database=test;host=127.0.0.1;port=$port";

        my $tries = 10;
        while($tries) {
            $dbh = DBI->connect($dsn, 'root', 'password');
            if($dbh) {
                last;
            }

            $tries--;

            note("Waiting for DB to come up");
            sleep(10);
        }

        unless($tries) {
            die "unable to connect to docker mysql instance";
        }

        return $dbh;
}
