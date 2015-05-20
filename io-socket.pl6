#!/usr/bin/env perl6


class HTTP::Server::Threaded::Request {
  has Str $.method;
  has Str $.resource;
  has Str $.version;
  has Str %.headers;
  has Buf $.data is rw;

  method header(*@headers) {
    my @r;
    my %h = @headers.map({ $_.lc => $_ });
    %.headers.keys.map(-> $k { 
      @r.push(%h{$k.lc} => %.headers{$k}) if $k.lc ~~ any %h.keys;
    });
    @r;
  }
};

class HTTP::Server::Threaded::Response {
  has $.connection;
};

class HTTP::Server::Threaded {

  has Int              $.port         = 8091;
  has Str              $.ip           = '0.0.0.0';
  has Supply           $!connections .=new; 
  has IO::Socket::INET $.server;     

  has @.mws;
  has @.hws;

  method middleware(Callable $sub) {
    @.mws.push($sub);
  }

  method handler(Callable $sub) {
    @.hws.push($sub);
  }

  method !eor($req, $data is rw) returns Bool {
    if $req.method ne 'POST' || $req.header('Content-Length', 'Transfer-Encoding').elems == 0 {
      return True;
    }
    my %headers = $req.header('Content-Length', 'Transfer-Encoding');
    if %headers.EXISTS-KEY('Content-Length') {
      return True if $data.elems == %headers<Content-Length>;
    }
    if %headers.EXISTS-KEY('Transfer-Encoding') && %headers<Transfer-Encoding>.lc eq 'chunked' {
      #scan from end to find out if it is complete;
      if $data.subbuf(*-3) ~~ Buf.new('0'.ord, 13, 10) {
        #TODO decode transfer-encoding: chunked 
        return True; 
      }
    }
    return False;
  }

  method !conn {
    start {
      $!connections.tap( -> $conn {
        my Buf  $data .=new;
        my Blob $sep   = "\r\n\r\n".encode;
        my $buf;
        my $done = 0;
        my $headercomplete = 0;
        my $req;
        my (%headers, $method, $resource, $version);
        while $buf = $conn.read(1) {
          CATCH { default { .say ; } }
          $data ~= $buf;
          if ! $headercomplete {
            for $data.elems-$buf.elems-4 .. $data.elems-1 -> $x {
              last if $x < 0;
              if $data.elems >= $x+4 && $data.subbuf($x, 4) eq $sep {
                $headercomplete = 1;
                my $i = 0;
                $data.subbuf(0, $x).decode.split("\r\n").map( -> $l {
                  if $i++ == 0 {
                    $l ~~ / ^^ $<method>=(\w+) \s $<resource>=(.+) \s $<version>=('HTTP/' .+) $$ /;
                    $method   = $<method>.Str;
                    $resource = $<resource>.Str;
                    $version  = $<version>.Str;
                    next; 
                  }
                  my @parse = $l.split(':', 2);
                  %headers{@parse[0].trim} = @parse[1].trim // Any;
                });
                $data .=subbuf($x + 4);
                $req = HTTP::Server::Threaded::Request.new(:$method, :$resource, :$version, :%headers);
                for @.mws -> $middle {
                  my $r = $middle($req);
                  if $r ~~ Promise {
                    await $r;
                    return unless $r.status;
                  }
                }
              }
            }
          }
          if $headercomplete && self!eor($req, $data) {
            $req.data = $data;
            for @.hws -> $handler {
              my $r = $handler($req, HTTP::Server::Threaded::Response.new(:connection($conn)));
              if $r ~~ Promise {
                await $r;
                if ! $r.status {
                  return;
                }
              }
            }
            $conn.close;
            $done = 1;
          }
          last if $done;
        }
      });
      await Promise.new;
    };
  }

  method listen {
    $!server      = IO::Socket::INET.new(:localhost($.ip), :localport($.port), :listen);
    self!conn;
    while (my $conn = $!server.accept) {
      $!connections.emit($conn);
    }
  }
}


my HTTP::Server::Threaded $s .=new(:ip<0.0.0.0>, :port(8091));

$s.handler(sub ($req, $res) {
  my $str = "{$req.method} {$req.resource} {$req.version}\r\n{$req.headers.keys.map({ "$_ => {$req.headers{$_}}" }).join("\r\n")}\r\n\r\n";
  $res.connection.send("HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: {$str.chars}\r\n\r\n$str");
});

$s.listen;
