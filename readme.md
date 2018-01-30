![mudle](https://github.com/f0x52/mudle/raw/master/mudle.png "mudle")
# mudle

a simple combination of a server and client, communicating over tcp 4004  
this is designed to run on a server, where users ssh in to use the client

design:
  each room has a json with info about it
  host on server, connect using ssh, client.pl runs in screen/tmux

# installation

```
perl -MCPAN -e shell
install Term::ANSIColor File::Util Digest::SHA Switch::Plain Data::Dumper JSON

sudo aptitude install libterm-readline-gnu-perl
```
