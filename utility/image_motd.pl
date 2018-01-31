#!/usr/bin/env perl

use strict;
use warnings;
use 5.010;

use Image::Magick;
use Switch::Plain;
use Term::ANSIColor;
use File::Util;

my ($img_path, $text_path) = @ARGV;
my $image = Image::Magick->new;
my $x = $image->Read($img_path);
my $f = File::Util->new;
my $text = $f->load_file($text_path);
my @lines = split /\n/, $text;

my $h = $image->Get('height');
my $w = $image->Get('width');

sub color_lookup {
    my ($p, @pixel) = @_;
    my $color = int($pixel[0]*256);
    sswitch ($color) {
        case '204': {return $p.'red'}
        case '181': {return $p.'green'}
        case '240': {return $p.'yellow'}
        case '129': {return $p.'blue'}
        case '178': {return $p.'magenta'}
        case '138': {return $p.'cyan'}
        case '0': {return $p.'black'}
        default : { say $color; return $p.'black'}
    }
}
my $l = -1 * int(($h/2 - scalar(@lines)) /2);
$l-- if scalar(@lines)%2;

for (my $y=0; $y<$h; $y=$y+2) {
    my $row = "";
    for (my $x=0; $x<$w; $x++) {
        $row .= color(color_lookup('', $image->GetPixel(x=>$x, y=>$y)));
        $row .= color(color_lookup('on_', $image->GetPixel(x=>$x, y=>$y+1)));
        $row .= "▀"
    }
    $row .= color('reset');
    $row .= " "x16 . $lines[$l] if $l > -1 && exists $lines[$l];
    say $row;
    $l++;
}
