#!/usr/bin/env perl

use 5.010;
use strict;
use warnings;
 
use threads;
use threads::shared;
 
use IO::Socket::INET;
use Time::HiRes qw(sleep ualarm);

use Term::ANSIColor;
use File::Util;
use Digest::SHA qw(sha256_hex);
use JSON;
 
my $HOST = "localhost";
my $PORT = 4004;

my $motd = "Welcome to lainMud\nhere are some rules\nand enjoy your stay!";
 
my @open;
my %users : shared;
 
sub broadcast {
    my ($id, $message) = @_;
    print "$message\n";
    foreach my $i (keys %users) {
        if ($i != $id) {
            $open[$i]->send("$message\n");
        }
    }
}
 
sub login {
    my ($conn) = @_;
 
    state $id = 0;
 
    threads->new(
        sub {
            while (1) {
                my $f = File::Util->new();
                $conn->recv(my $auth_str, 1024, 0);
                my @auth = split / /, $auth_str;
                if(scalar(@auth) != 3) {
                    $conn->send("please login with \"login user password\"");
                    next;
                }

                my $name     = $auth[1];
                my $password = $auth[2];
                my $hash     = sha256_hex($password);

                my $path = "data/users/" . $f->escape_filename($name) . ".json";

                my $json = JSON->new;
                if (-f $path) { #user.json exists
                    my $json_str = $f->load_file($path);
                    my $userdata = $json->decode(<$json_str>);
                    say $userdata;
                } else {
                    my $user_hash = {user=>$name, pass=>$hash};
                    my $object = $json->encode($user_hash);
                    say $json;
                }

 
                if (exists $users{$name}) {
                    $conn->send("Name entered is already in use.\n");
                }
                elsif ($name ne '') {
                    $users{$id} = $name;
                    broadcast($id, "+++ $name arrived +++");
                    $conn->send("success\n");
                    $conn->send($motd . "\n");
                    last;
                }
            }
        }
    );
 
    ++$id;
    push @open, $conn;
}
 
my $server = IO::Socket::INET->new(
                                   Timeout   => 0,
                                   LocalPort => $PORT,
                                   Proto     => "tcp",
                                   LocalAddr => $HOST,
                                   Blocking  => 0,
                                   Listen    => 1,
                                   Reuse     => 1,
                                  );
 
local $| = 1;
print "Listening on $HOST:$PORT\n";
 
while (1) {
    my ($conn) = $server->accept;
 
    if (defined($conn)) {
        login $conn;
    }
 
    foreach my $i (keys %users) {
 
        my $conn = $open[$i];
        my $message;
 
        eval {
            local $SIG{ALRM} = sub { die "alarm\n" };
            ualarm(500);
            $conn->recv($message, 1024, 0);
            ualarm(0);
        };
 
        if ($@ eq "alarm\n") {
            next;
        }
 
        if (defined($message)) {
            if ($message ne '') {
                #$message = unpack('A*', $message);
                broadcast($i, color('reset blue') . "[$users{$i}] " . color('reset') . $message);
            }
            else {
                broadcast($i, "--- $users{$i} leaves ---");
                delete $users{$i};
                undef $open[$i];
            }
        }
    }
 
    sleep(0.1);
}
