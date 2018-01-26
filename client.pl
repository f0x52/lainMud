#!/usr/bin/perl

use 5.010;
use strict;
use POSIX;
use Term::ReadLine;
use Term::ANSIColor;
require Term::ReadLine::Gnu;
use IO::Socket;
use IO::Select;
use threads;
use threads::shared;

my @pair = (qw(localhost 4004));

my $user   = %ENV{'USER'};
my $cmds   : shared = "";
my $prompt : shared = "\001\r" . color('reset bold yellow') . "\002[$user] " . "\001" . color('reset') . "\002";
                      #put \001, \002 around non-printing characters
my $done   : shared = 0;

my $term     = new Term::ReadLine "lainMud";
my $listener = new threads( \&listener );

&sender;
$listener->join;

exit;
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

    my $buf = undef;
    recv($sock, $buf, 1024, 0);
    if ($buf) {
        if (substr($buf, 0, 7) ne "success") {
            print "\x1b[2K\r" . color('red') . "fatal login error: " . $buf . "\n" . color('reset'); #\x1b[2K = clear line
            $done = 1;
            return;
        }
    }
    print "\x1b[2K\r".substr($buf, 0, 7); #\x1b[2K = clear line
    $term->forced_update_display;
    while( $sock->connected ) {
        if( $sele->can_read(0.1) ) {
            my $buf = undef;
            my $sock_addr = recv( $sock, $buf, 1024, 0 );
            
            if( not defined $sock_addr ) {
                die "socket error";
            }   

            if( not $buf ) {
                if( (++ $eb_count) >= 20 ) {
                    warn "connection terminated\n(return to quit)\n";
                    $done = 1;
                    return;
                }
            }

            if( $buf ) {
                print "\x1b[2K\r".$buf; #\x1b[2K = clear line
                $term->set_prompt( $prompt );
                $term->forced_update_display;
                $eb_count = 0;
            }

        }

        if( $cmds ) {
            lock $cmds;
            print $sock $cmds;
            my $cols = `tput cols`;
            my $lines = ceil(length($cmds) / $cols);
            print "\x1b[F \x1b[2K\r" x $lines; 
                # \x1b[F = go 1 line up, \x1b[2K clears that line, 
                # do this for the amount of lines writing the message took
            print "\001\r" . color('reset red') . "\002[$user]" . color('reset') . " " . $cmds;
            $term->forced_update_display;
            $cmds = "";
        }
    }
    shutdown $sock, 2;
}
