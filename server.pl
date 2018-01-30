#!/usr/bin/env perl

use 5.012;
use strict;
use warnings;
use autodie;
 
use IO::Socket::INET;
use Time::HiRes qw(sleep ualarm);

use Term::ANSIColor;
use File::Util;
use Digest::SHA qw(sha256_hex);
use File::Path qw(make_path);
use JSON;
use Switch::Plain;
use Data::Dumper;

use threads;
use threads::shared;
 
my $HOST = "localhost";
my $PORT = 4004;

my $f = File::Util->new;
my $motd = $f->load_file('motd.txt');
 
my @open;

my %users : shared;
my %ids : shared;

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

sub send_str {
    my ($socket, $str) = @_;
    my $pack = pack("L A*", length($str), $str);
    $socket->send($pack);
}

sub broadcast {
    my ($id, $message) = @_;
    print "$message\n";
    foreach my $i (keys %users) {
        if ($i != $id) {
            send_str($open[$i], "$message\n");
        }
    }
}

#moo subs

sub get_location {
    my ($user) = @_;
    my $json = JSON->new;
    $json->allow_nonref->utf8;
    my %user_json = load_json($json, "data/users/$user.json");
    my $location = $user_json{location};
    my %new_room = load_json($json, "data/rooms/$location.json");

    my $presence = get_list($user, @{ $new_room{users} });

    return color('bold') . $new_room{name} . " #$location" . color('reset') . "\n" .
           $new_room{desc} . "\n" .
           "you see: " . join(", ", keys(%{ $new_room{objects} })) . "\n" .
           "you can go: ( " . join(" ", keys( %{ $new_room{map} } )) . " )\n" .
           $presence;

}

sub get_list {
    my ($user, @room_users) = @_;
    my $presence;
    my @online = get_online($user, @room_users);
    if (scalar(@online) == 0) {
        $presence = "$user is here\n";
    } else {
        $presence = join(", ", @online) . " and $user are here\n";
    }
    return $presence;
}

sub get_online {
    my ($user, @users) = @_;
    my @response;
    foreach (@users) {
        next if $_ eq $user;
        if (exists $ids{$_}) {
            push @response, $_;
        }
    }
    return @response;
}

sub look {
    my ($id, $user) = @_;

    my $json = JSON->new;
    $json->allow_nonref->utf8;
    my %user_json = load_json($json, "data/users/$user.json");
    my $location = $user_json{location};
    my %room = load_json($json, "data/rooms/$location.json");
    my %objects = %{ $room{objects} };
    my $str = color('bold') . "You see:\n" . color('reset');
    foreach my $short (keys %objects) {
        my %object = load_json($json, "data/objects/$objects{$short}.json");
        $str .= $object{name} . " [$short] #$objects{$short}\n";
        $str .= "  " . $object{desc} . "\n";
        $str .= "  actions: " . join(", ", keys( %{ $object{actions} } )) . "\n";
    }
    send_str($open[$id], $str);
}
 
sub move {
    my ($id, $user, $direction) = @_;

    my $json = JSON->new;
    $json->allow_nonref->utf8;
    my %user_json = load_json($json, "data/users/$user.json");
    my $location = $user_json{location};
    my %room = load_json($json, "data/rooms/$location.json");

    if (exists($room{map}{$direction})) {
        #this is a valid $direction, move there
        say "MOVE: $user moved $direction";
        my $dest = $room{map}{$direction};
        move_user($user, $location, $dest);
    } else {
        say "$user tried to move";
        send_str($open[$id], "you can't move there\n");
    }
}

sub move_user {
    my ($user, $from, $dest) = @_;
    my $json = JSON->new;
    $json->allow_nonref->utf8;

    my %room = load_json($json, "data/rooms/$from.json");
    my @current_users = @{ $room{users} };
    my $index = 0;
    $index++ until $current_users[$index] eq $user or $index > scalar(@current_users);
    splice(@current_users, $index, 1);
    $room{users} = [ @current_users ];

    my $content = $json->encode(\%room);
    my $f = File::Util->new;
    
    $f->write_file(
        'file' => "data/rooms/$from.json",
        'content' => $content,
        'bitmask' => 0644
    );

    my %user_json = load_json($json, "data/users/$user.json");
    $user_json{location} = $dest;
    $content = $json->encode(\%user_json);
    
    $f->write_file(
        'file' => "data/users/$user.json",
        'content' => $content,
        'bitmask' => 0644
    );

    my %new_room = load_json($json, "data/rooms/$dest.json");
    my @new_room_users = @{ $new_room{users} };
    push @new_room_users, $user;
    $new_room{users} = [ @new_room_users ];
    $content = $json->encode(\%new_room);
    
    $f->write_file(
        'file' => "data/rooms/$dest.json",
        'content' => $content,
        'bitmask' => 0644
    );
    send_str($open[$ids{$user}], get_location($user));
    roomtalk($from, $user, "$user left your room");
    roomtalk($dest, $user, "$user joined your room");
}

sub roomtalk {
    my ($room, $user, $msg) = @_;
    my $json = JSON->new;
    $json->allow_nonref->utf8;
    my %room_json = load_json($json, "data/rooms/$room.json");
    my @recv_users = @{ $room_json{users} };
    foreach (@recv_users) {
        next if $_ eq $user;
        if (exists $ids{$_}) { #check if it exists
            send_str($open[$ids{$_}], "$msg\n");
        }
    }
    print "ROOM: $room $msg\n";
}

sub teleport {
    my ($i, $user, $dest) = @_;
    my $json = JSON->new;
    $json->allow_nonref->utf8;
    my %user_json = load_json($json, "data/users/$user.json");
    my $from = $user_json{location};
    if (-f "data/rooms/$dest.json") {
        #destination is a room
        move_user($user, $from, $dest);
    } else {
        send_str($open[$i], "that's not a valid room\n");
    }

}

sub dig {
    my ($i, $user) = @_;
    my $room_count = $f->load_file("data/rooms/room_count");
    $room_count++;
    $room_count++ while (-f "data/rooms/$room_count.json");
    
    #because doing empty arrays/hashes is a pain
    my $new_room = '{"users":[],"desc":"empty description","map":{},"name":"a brand new room","objects":[]}';

    $f->write_file(
        'file' => "data/rooms/$room_count.json",
        'content' => $new_room,
        'bitmask' => 0644
    );

    $f->write_file(
        'file' => "data/rooms/room_count",
        'content' => $room_count,
        'bitmask' => 0644
    );
    say "DIG: $user dug $room_count";
    send_str($open[$i], "Room created at #$room_count");
}

sub new {
    my ($i, $user) = @_;
    my $object_count = $f->load_file("data/objects/object_count");
    $object_count++;
    $object_count++ while (-f "data/objects/$object_count.json");
    
    #because doing empty arrays/hashes is a pain
    my $new_object = '{"desc":"doesnt do much", "name":"a brand new object", "actions":{}}';

    $f->write_file(
        'file' => "data/objects/$object_count.json",
        'content' => $new_object,
        'bitmask' => 0644
    );

    $f->write_file(
        'file' => "data/objects/object_count",
        'content' => $object_count,
        'bitmask' => 0644
    );
    say "NEW: $user created $object_count";
    send_str($open[$i], "created object #$object_count");
}

sub edit_room {
    my ($user, @command) = @_;
    shift @command;
    if (scalar(@command) < 1) {
        send_str($open[$ids{$user}], "not enough arguments");
        return;
    }
    my $json = JSON->new;
    $json->allow_nonref->utf8;
    my %user_json = load_json($json, "data/users/$user.json");
    my $room = $user_json{location};

    my %room_json = load_json($json, "data/rooms/$room.json");
    my $option = shift @command;
    if (exists $command[0]) {
        #modify option
        my $str = join(" ", @command);
        sswitch ($option) {
            case 'name': { $room_json{name} = $str }
            case 'desc': { $room_json{desc} = $str }
            case 'map': { 
                if ($command[0] eq 'add') {
                    if (-f "data/rooms/$command[2]") {
                        $room_json{map}{$command[1]} = $command[2];
                    } else {
                        send_str($open[$ids{$user}], "that room doesn't exist");
                    }
                } elsif ($command[0] eq 'del') {
                    delete $room_json{map}{$command[1]};
                } else {
                    send_str($open[$ids{$user}], "unknown operation on map");
                    return;
                }
            }
            case 'objects': {
                if ($command[0] eq 'add') {
                    if (-f "data/objects/$command[2]") {
                        $room_json{objects}{$command[1]} = $command[2];
                    } else {
                        send_str($open[$ids{$user}], "that object doesn't exist");
                    }
                } elsif ($command[0] eq 'del') {
                    delete $room_json{objects}{$command[1]};
                } else {
                    send_str($open[$ids{$user}], "unknown operation on objects");
                    return;
                }

            }
        }
        my $content = $json->encode(\%room_json);
        $f->write_file(
            'file' => "data/rooms/$room.json",
            'content' => $content,
            'bitmask' => 0644
        );
        say("EDIT: $room $option by $user to $command[1]");
        send_str($open[$ids{$user}], "changed $option for room $room");
        send_str($open[$ids{$user}], get_location($user));
        look($ids{$user}, $user);
    } else {
        #return option value
        send_str($open[$ids{$user}], Dumper($room_json{$option}));
    }
}

sub edit_object {
    my ($user, @command) = @_;
    shift @command;
    if (scalar(@command) < 1) {
        send_str($open[$ids{$user}], "not enough arguments");
        return;
    }
    my $json = JSON->new;
    $json->allow_nonref->utf8;
    my $object = shift @command;
    my %object_json = load_json($json, "data/objects/$object.json");
    my $option = shift @command;
    if (exists $command[0]) {
        #modify option
        my $str = join(" ", @command);
        sswitch ($option) {
            case 'name':  { $object_json{name}  = $str }
            case 'desc':  { $object_json{desc}  = $str }
        }
        my $content = $json->encode(\%object_json);
        $f->write_file(
            'file' => "data/objects/$object.json",
            'content' => $content,
            'bitmask' => 0644
        );
        say("EDIT: $object $option by $user to $command[1]");
        send_str($open[$ids{$user}], "changed $option for object $object");
        look($ids{$user}, $user);
    } else {
        #return option value
        send_str($open[$ids{$user}], Dumper($object_json{$option}));
    }
}

sub interact {
    my ($id, $user, $action, @command) = @_;
    if (scalar(@command) > 0) {
        my $object = shift @command;
        my $json = JSON->new;
        $json->allow_nonref->utf8;

        my %user_json = load_json($json, "data/users/$user.json");
        my $location = $user_json{location};

        my %room_json = load_json($json, "data/rooms/$location.json");
        if (exists($room_json{objects}{$object})) {
            my %object_json = load_json($json, "data/objects/$room_json{objects}{$object}.json");
            if (exists($object_json{actions}{$action})) {
                my $str = "";
                eval($object_json{actions}{$action});

                my $content = $json->encode(\%object_json);
                $f->write_file(
                    'file' => "data/objects/$object.json",
                    'content' => $content,
                    'bitmask' => 0644
                );

                if ($str ne "") {
                    send_str($open[$id], $str);
                }
            } else {
                send_str($open[$id], "you can't $action $object");
            }
        } else {
            #can't find $object in room
            send_str($open[$id], "you can't find $object");
        }

    } else {
        send_str($open[$id], "what do you want to $action?");
    }
}

sub login {
    my ($conn) = @_;
 
    state $id = 0;

    # TODO: better error handling, so server doesn't crash
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

            my $user     = $f->escape_filename($auth[1]);
            my $password = $auth[2];
            my $hash     = sha256_hex($password);

            my $path = "data/users/" . $user . ".json";

            my $json = JSON->new;
            $json->allow_nonref->utf8;
            my $authenticated = 0;
            if (-f $path) { #user.json exists
                my %j_data = load_json($json, $path);

                if ($hash eq $j_data{pass}) {
                    say $user . " login success";
                    $authenticated = 1;
                } else {
                    $conn->send("wrong password");
                    next;
                }
            } else {
                if ($user eq '') {
                    send_str($conn, "can't have a blank name");
                    next;
                }
                my $user_hash = {pass=>$hash, location=>0};
                my $object = $json->encode($user_hash);

                $f->write_file(
                    'file' => $path,
                    'content' => $object,
                    'bitmask' => 0644
                );

                my %new_room = load_json($json, "data/rooms/0.json");
                my @new_room_users = @{ $new_room{users} };
                push @new_room_users, $user;
                $new_room{users} = [ @new_room_users ];
                my $content = $json->encode(\%new_room);
                
                $f->write_file(
                    'file' => "data/rooms/0.json",
                    'content' => $content,
                    'bitmask' => 0644
                );
                roomtalk(0, $user, "$user joined your room");

                say $user . " register success";
                $authenticated = 1;
            }
            
            next if !$authenticated;
            $users{$id} = $user;
            $ids{$user} = $id;
            broadcast($id, "+++ $user arrived +++");

            send_str($conn, "success".$motd . "\n\n".get_location($user));
            last;
        }
    });
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
            my $user = $users{$i};
            if ($message ne '') {
                $message = unpack('A*', $message);
                if (substr($message, 0, 1) eq '/') {
                    #command
                    my @command = split / /, substr($message, 1);
                    sswitch ($command[0]) {
                        case 'info':  { send_str($open[$i], get_location($user)); }
                        case 'look':  { look($i, $user) }
                        case 'tp':    { teleport($i, $user, $command[1]) }
                        case 'dig':   { dig($i, $user) }
                        case 'new':   { new($i, $user) }
                        case 'edit':  { edit_room($user, @command) }
                        case 'edit_o':{ edit_object($user, @command) }
                        case 'list':  { 
                                        my $json = JSON->new;
                                        $json->allow_nonref->utf8;
                                        my %user_json = load_json($json, "data/users/$user.json");
                                        my $location = $user_json{location};
                                        say "$user is listing $location";
                                        my %room = load_json($json, "data/rooms/$location.json");
                                        my $presence = get_list($user, @{ $room{users} });
                                        send_str($open[$i], $presence);
                                      }
                    }
                } elsif (substr($message, 0, 1) eq ',') {
                    $message = substr($message, 1);
                    my $json = JSON->new;
                    $json->allow_nonref->utf8;
                    my %room = load_json($json, "data/users/" . $user . ".json");
                    roomtalk($room{location}, $user, "[$user] $message");
                } elsif (substr($message, 0, 1) eq '.') {
                    my @command = split / /, substr($message, 1);
                    my $output = 0; 
                    foreach (@command) {
                        move($i, $user, $_);
                        $output++;
                    }
                } elsif (substr($message, 0, 1) eq '!') {
                    my @command = split / /, substr($message, 1);
                    my $action = shift @command;
                    interact($i, $user, $action, @command);
                } else { 
                    #global chat
                    broadcast($i, "[$user] $message");
                }
            }
            else {
                broadcast($i, "--- $user leaves ---");
                delete $users{$i};
                delete $ids{$i};
                undef $open[$i];
            }
        }
    }
 
    sleep(0.1);
}
