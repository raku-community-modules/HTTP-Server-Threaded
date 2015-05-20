#!/usr/bin/env perl6

use lib 'lib';
use HTTP::Server::Threaded;

my HTTP::Server::Threaded $s .=new(:ip<0.0.0.0>, :port(8091));

$s.handler(sub ($req, $res) {
  my $str = "{$req.method} {$req.resource} {$req.version}\r\n{$req.headers.keys.map({ "$_ => {$req.headers{$_}}" }).join("\r\n")}\r\n\r\n";
  $res.close($str);
});

$s.listen;
