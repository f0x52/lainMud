#!/usr/bin/env perl

use 5.010;
use strict;
use warnings;
use autodie;
 
use threads;
use threads::shared;
 
use IO::Socket::INET;
use Time::HiRes qw(sleep ualarm);

use Term::ANSIColor;
use File::Util;
use Digest::SHA qw(sha256_hex);
use File::Path qw(make_path);
use JSON;
use Switch;
 
my $HOST = "localhost";
my $PORT = 4004;

my $motd = "Welcome to lainMud\nhere are some rules\nand enjoy your stay!";
 
my @open;
my %users : shared;

if(!-d "data/users") {
    make_path("data/users");
}

if(!-d "data/rooms") {
    make_path("data/rooms");
}

sub load_json {
    my ($json, $path) = @_;
    my $json_str = do {
        open(my $json_fh, "<:encoding(UTF-8)", $path);
        local $/;
        <$json_fh>
    };
    my $data = $json->decode($json_str);
    return %$data;
}

sub move {
    my ($id, $user, $direction) = @_;

    my $json = JSON->new;
    $json->allow_nonref->utf8;
    my %user_json = load_json($json, "data/users/$user.json");
    my $location = $user_json{location};
    my %room = load_json($json, "data/rooms/$location.json");
    if (exists($room{$direction})) {
        #this is a valid $direction, move there
        say "$user moved $direction";
        $user_json{location} = $room{$direction};
        my $content = $json->encode(\%user_json);
        my $f = File::Util->new;
        
        $f->write_file(
            'file' => "data/users/$user.json",
            'content' => $content,
            'bitmask' => 0644
        );
        $location = $user_json{location};
        my %new_room = load_json($json, "data/rooms/$location.json");
        $open[$id]->send("moved to " . $new_room{name} . "\n");
    } else {
        say "$user tried to move";
        $open[$id]->send("you can't move there\n");
    }
}
 
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
                my $f = File::Util->new;
                $conn->recv(my $auth_str, 1024, 0);
                $auth_str = unpack('A*', $auth_str);
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
                $json->allow_nonref->utf8;
                my $authenticated = 0;
                if (-f $path) { #user.json exists
                    my %j_data = load_json($json, $path);

                    if ($hash eq $j_data{pass}) {
                        say $name . " login success";
                        $authenticated = 1;
                    } else {
                        $conn->send("wrong password");
                        next;
                    }
                } else {
                    if ($name eq '') {
                        $conn->send("can't have a blank name");
                        next;
                    }
                    my $user_hash = {pass=>$hash, location=>0};
                    my $object = $json->encode($user_hash);

                    $f->write_file(
                        'file' => $path,
                        'content' => $object,
                        'bitmask' => 0644
                    );
                    $authenticated = 1;
                }
                
                next if !$authenticated;
                $users{$id} = $name;
                broadcast($id, "+++ $name arrived +++");
                my %user_json = load_json($json, "data/users/$name.json");
                my $location  = $user_json{location};
                my %user_room = load_json($json, "data/rooms/$location.json");
                $conn->send("success".
                $motd . "\n\n\n".
                "you are currently in " . $user_room{name} . ".");
                last;
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
                $message = unpack('A*', $message);
                if (substr($message, 0, 1) eq '/') {
                    #command
                    my @command = split / /, substr($message, 1);
                    switch ($command[0]) {
                        case "mov" { move($i, $users{$i}, $command[1]) }
                    }
                } else { 
                    #global (for now) chat
                    broadcast($i, color('reset blue') . "[$users{$i}] " . color('reset') . $message);
                }
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
