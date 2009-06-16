#!/usr/bin/perl

use strict;
use warnings;

use lib 'lib';
use lib 'extlib/lib/perl5';
use local::lib 'extlib';
use POE qw/Component::IRC::State Component::IRC::Plugin::Connector Component::Server::HTTP/;
use URI::QueryParam;
use YAML qw/LoadFile/;
use Template;
use JSON;
use Encode;
use HTML::Entities;
use IRC::Formatting;
use Time::HiRes qw/usleep/;
use List::MoreUtils qw/uniq/;

my @open_responses;
my $header = "Content-Type: text/plain\r\n\r\n";
my $seperator = "--xbuttesfirex";

my $config = LoadFile($ENV{HOME}.'/.buttesfire.yaml');
my $tt = Template->new(INCLUDE_PATH => 'data/templates');

my $http = POE::Component::Server::HTTP->new(
  Port             => 8080,
  ContentHandler   => {
    '/view'        => \&send_index,
    '/stream'      => \&setup_stream,
    '/favicon.ico' => \&not_found,
    '/say'         => \&handle_message,
    '/static'      => \&handle_static,
  },
  StreamHandler    => \&handle_stream,
);
my $irc = POE::Component::IRC::State->spawn(
  nick    => $config->{nick}    || 'nick',
  ircname => $config->{ircname} || 'nick',
  server  => $config->{server}  || 'irc.freenode.org',
  port    => $config->{port}    || 6667,
);

POE::Session->create(
  package_states => [
    main => [qw/_start irc_public irc_001 irc_join irc_part irc_quit irc_chan_sync/]
  ],
);

$poe_kernel->run;

sub setup_stream {
  my ($req, $res) = @_;
  $res->streaming(1);
  $res->code(200);
  $res->content_type('multipart/x-mixed-replace; boundary=xbuttesfirex');
  $res->header(Connection => 'close');
  $res->{seperator} = $req->header('User-Agent') =~ /Safari/ ? 
                      "\n$seperator\n$header$seperator\n" : "\n$seperator\n";
  $res->{msgs} = [];
  $res->{actions} = [];
  $res->{length} = 0;
  push @open_responses, $res;
  log_debug("opening a streaming http connection");
  return 200;
}

sub handle_stream {
  my ($req, $res) = @_;
  
  usleep(10_000);
  
  if ($res->is_error or $res->{length} > 50_000) {
    log_debug("closing HTTP connection");
    for (0 .. $#open_responses - 1) {
      if ($res == $open_responses[$_]) {
        splice(@open_responses, $_, 1);
        print @open_responses;
      }
    }
    $res->close;
    $res->continue;
    return;
  }
  if (@{$res->{actions}} or @{$res->{msgs}}) {
    my $output;
    
    if (! $res->{started}) {
      $res->{started} = 1;
      $output .= "$seperator\n";
    }
    
    $output .= $header;
    $output .= to_json({msgs => $res->{msgs}, actions => $res->{actions}});
    $output .= $res->{seperator};
    
    $res->{length} += length $output;
    $output .= "\n$seperator--\n" if $res->{length} > 50_000;
    $res->send($output) if @{$res->{msgs}} or @{$res->{actions}};
    
    if ($res->is_error) {
      $res->close;
      $res->continue;
      return;
    }
    else {
      $res->{msgs} = [];
      $res->{actions} = []; 
    }
  }
  else {
    $res->continue;
  }
}

sub handle_message {
  my ($req, $res) = @_;
  $res->streaming(0);
  my $msg = $req->uri->query_param('msg');
  if (defined $msg and length $msg and 
      my $chan = $req->uri->query_param('chan')) {
    if ($msg =~ /^\/join (.+)/) {
      $irc->yield( join => $1);
      return 200;
    }
    log_debug("sending message to $chan");
    $irc->yield( privmsg => $chan => $msg);
    display_message($config->{nick}, $chan, $msg);
  }
  $res->code(200);
  return 200;
}

sub handle_static {
  my ($req, $res) = @_;
  $res->streaming(0);
  my $file = $req->uri->query_param("f");
  my ($ext) = ($file =~ /[^\.]\.(.+)$/);
  if (-e "data/static/$file") {
    open my $fh, '<', "data/static/$file";
    log_debug("serving static file: $file");
    if ($ext =~ /png|gif|jpg|jpeg/i) {
      $res->content_type("image/$ext"); 
    }
    elsif ($ext =~ /js/) {
      $res->content_type("text/javascript");
    }
    elsif ($ext =~ /css/) {
      $res->content_type("text/css");
    }
    my @file = <$fh>;
    $res->code(200);
    $res->content(join "", @file);
    return 200;
  }
  not_found($req, $res);
}

sub send_index {
  my ($req, $res) = @_;
  log_debug("server index");
  $res->code(200);
  $res->streaming(0);
  $res->content_type('text/html; charset=utf-8');
  my $output = '';
  $tt->process('index.tt', {
    channels => [ map {
      {name => $_, topic => $irc->channel_topic($_)}
    } uniq(@{$config->{channels}}, keys %{$irc->channels}) ]
  }, \$output) or die $!;
  $res->content($output);
  return 200;
}

sub not_found {
  my ($req, $res) = @_;
  log_debug("serving 404:", $req->uri->path);
  $res->streaming(0);
  $res->code(404);
  return 404;
}

sub _start {
  $irc->yield( register => 'all' );
  $irc->plugin_add('Connector' => POE::Component::IRC::Plugin::Connector->new);
  $irc->yield( connect => { } );
  log_info("You can view your IRC session at: http://localhost:8080/view");
  log_debug("connected to irc server");
  return;
}

sub irc_001 {
  for (@{$config->{channels}}) {
    log_debug("joining $_");
    $irc->yield( join => $_ );
  }
}

sub irc_public {
  my ($who, $where, $what) = @_[ARG0 .. ARG2];
  my $nick = ( split /!/, $who )[0];
  my $channel = $where->[0];
  display_message($nick, $channel, $what);
}

sub irc_join {
  my ($who, $where) = @_[ARG0, ARG1];
  my $nick = ( split /!/, $who)[0];
  my $channel = $where;
  if ($nick ne $config->{nick}) {
    display_event($nick, $channel, "joined");  
  }
  else {
    create_tab($channel);
  }
}

sub irc_chan_sync {
  my ($channel) = @_;
  create_tab($channel) if $channel ne "main";
}

sub irc_part {
  my ($who, $where, $msg) = @_[ARG0 .. ARG2];
  my $nick = ( split /!/, $who)[0];
  my $channel = $where;
  display_event($nick, $channel, "left", $msg);
}

sub irc_quit {
  my ($who, $msg, $channels) = @_[ARG0 .. ARG2];
  my $nick = ( split /!/, $who)[0];
  for my $channel (@$channels) {
    display_event($nick, $channel, "quit", $msg);
  }
}

sub display_event {
  my ($nick, $channel, $event_type, $msg) = @_;
  my $event = {
    type      => "event",
    nick      => $nick,
    channel   => $channel,
    event     => $event_type,
    message   => $msg,
    timestamp => make_timestamp(),
  };
  add_outgoing($event, "event");
}

sub display_message {
  my ($nick, $channel, $text) = @_;
  my $msg = {
    type      => "message",
    nick      => $nick,
    channel   => $channel,
    self      => $nick eq $config->{nick},
    html       => decode_utf8(IRC::Formatting->formatted_string_to_html($text)),
    timestamp => make_timestamp(),
  };
  add_outgoing($msg, "message");
}

sub create_tab {
  my ($name) = @_;
  my $action = {
    type      => "join",
    name      => $name,
    timestamp => make_timestamp(),
  };
  my $chan_html = '';
  $tt->process("channel.tt", {channel => {name => $name}}, \$chan_html);
  $action->{html}{channel} = $chan_html;
  my $tab_html = '';
  $tt->process("tab.tt", {channel => {name => $name}}, \$tab_html);
  $action->{html}{tab} = $tab_html;
  log_debug("sending a request for a new tab: $name") if @open_responses;
  push @{$_->{actions}}, $action for @open_responses;
}

sub add_outgoing {
  my ($hashref, $type) = @_;
  my $html = '';
  $tt->process("$type.tt", $hashref, \$html);
  $hashref->{full_html} = decode_utf8($html);
  log_debug("adding $type to response queues") if @open_responses;
  push @{$_->{msgs}}, $hashref for @open_responses;
}

sub make_timestamp {
  return sprintf("%02d:%02d", localtime[2,1])
}

sub log_debug {
  return unless $config->{debug};
  print STDERR join " ", @_, "\n";
}

sub log_info {
  print STDERR join " ", @_, "\n";
}