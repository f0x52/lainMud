a simple combination of a server and client, communicating over tcp 4004  
this is designed to run on a server, where users ssh in to use the client

design:
  each room has a json with info about it
  host on server, connect using ssh, client.pl runs in screen/tmux

