#!/usr/bin/perl

use strict;
use warnings;
use diagnostics;
use autodie;
use 5.24.0;
use IO::Async::Stream;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use Socket qw( SOCK_STREAM );
use Data::Dumper;

use Term::ANSIColor;
use File::Util;
use Digest::SHA qw(sha256_hex);
use File::Path qw(make_path);
use JSON;
use Switch::Plain;

my $f = File::Util->new;
my $motd = $f->load_file('motd.txt');
 
my @open;
my %users;
my %ids;

if(!-d "data/users") {
    make_path("data/users");
}

if(!-d "data/rooms") {
    make_path("data/rooms");
}

sub load_json {
    my ($json, $path) = @_;
    say "loading $path";
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
    return if !$socket;
    my $pack = pack("L A*", length($str), $str);
    $socket->write($pack);
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
    my %room = load_json($json, "data/rooms/$location.json");

    my $str = "";
    foreach my $object (values( %{ $room{objects} })) {
        my %object_json = load_json($json, "data/objects/$object.json");
        if (exists($object_json{on_enter})) {
            eval($object_json{on_enter});

            my $content = $json->encode(\%object_json);
            $f->write_file(
                'file' => "data/objects/$object.json",
                'content' => $content,
                'bitmask' => 0644
            );
        }
    }

    my $presence = get_list($user, @{ $room{users} });

    return color('bold') . $room{name} . " #$location" . color('reset') . "\n" .
           $room{desc} . "\n" .
           "you see: " . join(", ", keys(%{ $room{objects} })) . "\n" . $str .
           "you can go: ( " . join(" ", keys( %{ $room{map} } )) . " )\n" .
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
    my $new_room = '{"users":[],"desc":"empty description","map":{},"name":"a brand new room","objects":{}}';

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

sub edit_user {
    my($user, @command) = @_;
    shift @command;
    if (scalar(@command) < 1) {
        send_str($open[$ids{$user}], "not enough arguments");
        return;
    }
    my $json = JSON->new;
    $json->allow_nonref->utf8;
    my %user_json = load_json($json, "data/users/$user.json");
    $user_json{desc} = join(" ", @command);
    my $content = $json->encode(\%user_json);
    $f->write_file(
        'file' => "data/users/$user.json",
        'content' => $content,
        'bitmask' => 0644
    );
    send_str($open[$ids{$user}], "changed your description to: " . join(" ", @command));
}

sub user_info {
    my($user, @command) = @_;
    shift @command;
    my $target;
    if (scalar(@command) < 1) {
        $target = $user;
    } else {
        $target = shift @command;
    }
    my $json = JSON->new;
    $json->allow_nonref->utf8;
    if (-f "data/users/$target.json") {
        my %user_json = load_json($json, "data/users/$target.json");
        if (!exists($user_json{desc})) {
            $user_json{desc} = "There's an air of mystery around $target";
            my $content = $json->encode(\%user_json);
            $f->write_file(
                'file' => "data/users/$target.json",
                'content' => $content,
                'bitmask' => 0644
            );
        }
        my %user_location = load_json($json, "data/rooms/$user_json{location}.json");
        my $online = color('red') . "(offline)" . color('reset');
        $online = color('green') . "(online)" . color('reset') if exists($ids{$target});
        my $str = "";
        $str .= color('bold') . $target . color('reset') . " $online\n";
        $str .= "  location:    $user_location{name} #$user_json{location}\n";
        $str .= "  description: $user_json{desc}\n";
        send_str($open[$ids{$user}], $str);
    } else {
        send_str($open[$ids{$user}], "that user doesn't exist");
    }
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
                    if (-f "data/rooms/$command[2].json") {
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
                    if (-f "data/objects/$command[2].json") {
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
    
    if (!-f "data/objects/$object.json") {
        send_str($open[$ids{$user}], "that object doesn't exist");
        return;
    }
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
                my $str   = "";
                my $broad = "";
                my $local = "";
                eval($object_json{actions}{$action});

                my $content = $json->encode(\%object_json);
                $f->write_file(
                    'file' => "data/objects/$room_json{objects}{$object}.json",
                    'content' => $content,
                    'bitmask' => 0644
                );

                if ($str ne "") {
                    send_str($open[$id], $str);
                }
                if ($broad ne "") {
                    broadcast($id, $broad);
                }
                if ($local ne "") {
                    roomtalk($location, '', $local);
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
    my ($conn, $auth_str) = @_;
    state $id = 0;
    my @auth = split / /, $auth_str;
    if(scalar(@auth) != 3) {
        $conn->write("please login with \"login user password\"");
        return 0;
    }

    my $user     = $f->escape_filename($auth[1]);
    my $password = $auth[2];
    my $hash     = sha256_hex($password);

    my $path = "data/users/" . $user . ".json";

    my $json = JSON->new;
    $json->allow_nonref->utf8;
    if (-f $path) { #user.json exists
        my %j_data = load_json($json, $path);

        if ($hash eq $j_data{pass}) {
            say $user . " login success";
        } else {
            $conn->write("wrong password");
            return 0;
        }
    } else {
        if ($user eq '') {
            send_str($conn, "can't have a blank name");
            return 0;
        }
        my $user_hash = {pass=>$hash, location=>0, desc=>"There's an air of mystery around $user"};
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
    }
    
    $users{$id} = $user;
    if (exists $ids{$user}) {
        if ($ids{$user}) {
            send_str($open[$ids{$user}], "a new session was established\n");
            $open[$ids{$user}]->close;
        }
    }
    $ids{$user} = $id;
    broadcast($id, "+++ $user arrived +++");

    send_str($conn, "success".$motd . "\n\n".get_location($user));
    $id++;
    return (1, $user);
}

my $loop = IO::Async::Loop->new();
$loop->listen(
    service   => 4004,
    socktype  => SOCK_STREAM,
    queuesize => 5,
    reuseaddr => 1,

    on_accept => sub {
        my ( $newclient ) = @_;
        push @open, $newclient;
        my $loggedin = 0;

        $loop->add(
            IO::Async::Stream->new(
                handle => $newclient,
                autoflush => 1,
                on_read => sub {
                    my ($conn, $buffref, $closed ) = @_;
                    my $message = unpack("A*", $$buffref);
                    state $user = "";
                    $$buffref = '';
                    my $username = "";
                    if (!$loggedin) {
                        ($loggedin, $user) = login($conn, $message);
                        return 0;
                    }
                    return 0 if !$loggedin;
                    my $i = $ids{$user};
                    say "-- $user --";
                    if ($message ne '') {
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
                                case 'me':    { shift @command; broadcast($i, "*$user " . join(" ", @command)) }
                                case 'desc':  { edit_user($user, @command) }
                                case 'who':   { user_info($user, @command) }
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
                    return 0;
                },
            ),
        );
    },
    on_resolve_error => sub { print STDERR "Cannot resolve - $_[0]\n"; },
    on_listen_error  => sub { print STDERR "Cannot listen\n"; },
);

my $timer = IO::Async::Timer::Periodic->new(
   interval => 120,
   on_tick => sub {
       say "TICK";
       my $json = JSON->new;
       $json->allow_nonref->utf8;
       my @rooms = <data/rooms/*.json>;
       foreach my $room (@rooms) {
           my %room_json = load_json($json, $room);
           $room =~ m/(\d+).json/;
           my $roomid = $1;
           foreach (keys(%{ $room_json{objects} })) {
               my $objectid = $room_json{objects}{$_};
               my %object_json = load_json($json, "data/objects/$objectid.json");
               if (exists($object_json{on_tick})) {
                   my $broad = "";
                   my $local = "";
                   eval($object_json{on_tick});

                   my $content = $json->encode(\%object_json);
                   $f->write_file(
                       'file' => $objectid,
                       'content' => $content,
                       'bitmask' => 0644
                   );

                   if ($broad ne "") {
                       broadcast(999999999, $broad);
                   }
                   if ($local ne "") {
                       roomtalk($roomid, '', $local);
                   }
               }
           }
           my $content = $json->encode(\%room_json);
           $f->write_file(
               'file' => $room,
               'content' => $content,
               'bitmask' => 0644
           );

       }
   },
);

say "listening on port 4004";
$timer->start;
$loop->add($timer);

$loop->loop_forever();

