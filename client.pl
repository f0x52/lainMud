#!/usr/bin/perl

use 5.010;
use strict;
use POSIX;
use Term::ReadLine;
use Term::ANSIColor;
require Term::ReadLine::Gnu;
use IO::Socket;
use IO::Select;
use File::Util;
use threads;
use threads::shared;

my @pair = (qw(localhost 4004));

my $file   = File::Util->new;
my $user   = %ENV{'USER'};
$user      = $file->escape_filename($user); #yes this happens serverside too!
my $cmds   : shared = "";
my $prompt : shared = "\001\r" . color('reset bold yellow') . "\002[$user] " . "\001" . color('reset') . "\002";
                      #put \001, \002 around non-printing characters
my $done   : shared = 0;

my $term     = new Term::ReadLine "lainMud";
my $listener = new threads( \&listener );

&sender;
$listener->join;

exit;

sub send_str {
    my ($socket, $str) = @_;
    my $pack = pack("L A*", length($str), $str);
    $socket->send($pack);
}

sub recv_str {
    my ($sock) = @_;
    my $buf = undef;
    recv($sock, $buf, 4, 0);
    if ($buf) {
        my $len = unpack("L", $buf);
        recv($sock, $buf, $len, 0);
        return unpack("A*", $buf);
    }
}

sub sender {
    while( defined(my $line = $term->readline($prompt)) ) {
        lock $cmds;
        $cmds .= "$line\n";
        return if $done;
    }   
}   

sub listener {
    my $sock = new IO::Socket::INET( PeerAddr => $pair[0], PeerPort =>
+ $pair[1], Proto => "tcp" );
    my $sele = new IO::Select;
    
    my $eb_count = 0;
    
    $sele->add( $sock );
    print $sock "login $user " . @ARGV[0];

    my $str = recv_str($sock);
    if (substr($str, 0, 7) ne "success") {
        say "\x1b[2K\r" . color('red') . "fatal login error: " . $str . "\n" . color('reset');
        $done = 1;
        return;
    }
    say "\x1b[2K\r".substr($str, 7);
    $term->forced_update_display;
    while( $sock->connected ) {
        if( $sele->can_read(0.1) ) {
            my $buf = recv_str($sock);

            if( not $buf ) {
                if( (++ $eb_count) >= 20 ) {
                    warn "connection terminated\n(return to quit)\n";
                    $done = 1;
                    return;
                }
            }

            if( $buf ) {
                my $c = () = $buf =~ /\\n/g;
                say "\x1b[2K\r" x ++$c . $buf; #\x1b[2K = clear line
                $term->forced_update_display;
                $eb_count = 0;
            }

        }

        if( $cmds ) {
            lock $cmds;
            print $sock $cmds;
            if (substr($cmds, 0, 1) ne '/') {
                my $cols = `tput cols`;
                my $lines = ceil(length($cmds) / $cols);
                print "\x1b[F \x1b[2K\r" x $lines; 
                    # \x1b[F = go 1 line up, \x1b[2K clears that line, 
                    # do this for the amount of lines writing the message took
                print "\001\r" . color('reset red') . "\002[$user]" . color('reset') . " " . $cmds;
            }
            $term->forced_update_display;
            $cmds = "";
        }
    }
    shutdown $sock, 2;
}
