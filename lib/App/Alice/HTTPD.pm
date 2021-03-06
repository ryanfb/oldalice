package App::Alice::HTTPD;

use AnyEvent;
use AnyEvent::HTTPD;
use AnyEvent::HTTP;
use App::Alice::Stream;
use App::Alice::CommandDispatch;
use MIME::Base64;
use JSON;
use Any::Moose;

has 'app' => (
  is  => 'ro',
  isa => 'App::Alice',
  required => 1,
);

has 'httpd' => (
  is  => 'rw',
  isa => 'AnyEvent::HTTPD'
);

has 'streams' => (
  is  => 'rw',
  auto_deref => 1,
  isa => 'ArrayRef[App::Alice::Stream]',
  default => sub {[]},
);

sub add_stream {push @{shift->streams}, @_}
sub no_streams {@{$_[0]->streams} == 0}
sub stream_count {scalar @{$_[0]->streams}}

has 'config' => (
  is => 'ro',
  isa => 'App::Alice::Config',
  lazy => 1,
  default => sub {shift->app->config},
);

has 'ping_timer' => (
  is  => 'rw',
);

sub BUILD {
  my $self = shift;
  my $httpd = AnyEvent::HTTPD->new(
    host => $self->config->http_address,
    port => $self->config->http_port,
  );
  $httpd->reg_cb(
    '/serverconfig' => sub{$self->server_config(@_)},
    '/config'       => sub{$self->send_config(@_)},
    '/save'         => sub{$self->save_config(@_)},
    '/tabs'         => sub{$self->tab_order(@_)},
    '/view'         => sub{$self->send_index(@_)},
    '/stream'       => sub{$self->setup_stream(@_)},
    '/favicon.ico'  => sub{$self->not_found($_[1])},
    '/say'          => sub{$self->handle_message(@_)},
    '/static'       => sub{$self->handle_static(@_)},
    '/get'          => sub{$self->image_proxy(@_)},
    '/logs'         => sub{$self->send_logs(@_)},
    '/search'       => sub{$self->send_search(@_)},
    'client_disconnected' => sub{$self->purge_disconnects(@_)},
    request         => sub{$self->check_authentication(@_)},
  );
  $self->httpd($httpd);
  $self->ping;
}

sub ping {
  my $self = shift;
  $self->ping_timer(AnyEvent->timer(
    after    => 5,
    interval => 10,
    cb       => sub {
      $self->broadcast([{
        type => "action",
        event => "ping",
      }]);
    }
  ));
}

sub image_proxy {
  my ($self, $httpd, $req) = @_;
  my $url = $req->url;
  $url =~ s/^\/get\///;
  http_get $url, sub {
    my ($data, $headers) = @_;
    $req->respond([$headers->{Status},$headers->{Reason},$headers,$data]);
  };
}

sub broadcast {
  my ($self, $data, $force) = @_;
  return if $self->no_streams or !@$data;
  $_->enqueue(@$data) for $self->streams;
  $_->broadcast for @{$self->streams};
};

sub check_authentication {
  my ($self, $httpd, $req) = @_;
  return unless ($self->config->auth
      and ref $self->config->auth eq 'HASH'
      and $self->config->auth->{username}
      and $self->config->auth->{password});

  if (my $auth  = $req->headers->{authorization}) {
    $auth =~ s/^Basic //;
    $auth = decode_base64($auth);
    my ($user,$password)  = split(/:/, $auth);
    if ($self->config->auth->{username} eq $user &&
        $self->config->auth->{password} eq $password) {
      return;
    }
    else {
      $self->log_debug("auth failed");
    }
  }
  $httpd->stop_request;
  $req->respond([401, 'unauthorized', {'WWW-Authenticate' => 'Basic realm="Alice"'}]);
}

sub setup_stream {
  my ($self, $httpd, $req) = @_;
  $self->log_debug("opening new stream");
  my $msgid = $req->parm('msgid') || 0;
  $self->add_stream(
    App::Alice::Stream->new(
      queue   => [
        $self->app->buffered_messages($msgid),
        map({$_->nicks_action} $self->app->windows),
      ],
      request => $req,
    )
  );
}

sub purge_disconnects {
  my ($self, $host, $port) = @_;
  $self->streams([
    grep {!$_->disconnected} $self->streams
  ]);
}

sub handle_message {
  my ($self, $httpd, $req) = @_;
  my $msg  = $req->parm('msg');
  my $source = $req->parm('source');
  my $window = $self->app->get_window($source);
  if ($window) {
    for (split /\n/, $msg) {
      eval {$self->app->dispatch($_, $window) if length $_};
      if ($@) {$self->log_debug($@)}
    }
  }
  $req->respond([200,'ok',{'Content-Type' => 'text/plain'}, 'ok']);
}

sub handle_static {
  my ($self, $httpd, $req) = @_;
  my $file = $req->url;
  my ($ext) = ($file =~ /[^\.]\.(.+)$/);
  my $headers;
  if (-e $self->config->assetdir . "/$file") {
    open my $fh, '<', $self->config->assetdir . "/$file";
    if ($ext =~ /^(?:png|gif|jpg|jpeg)$/i) {
      $headers = {"Content-Type" => "image/$ext"};
    }
    elsif ($ext =~ /^js$/) {
      $headers = {
        "Cache-control" => "no-cache",
        "Content-Type" => "text/javascript",
      };
    }
    elsif ($ext =~ /^css$/) {
      $headers = {
        "Cache-control" => "no-cache",
        "Content-Type" => "text/css",
      };
    }
    else {
      return $self->not_found($req);
    }
    my @file = <$fh>;
    $req->respond([200, 'ok', $headers, join("", @file)]);
    return;
  }
  $self->not_found($req);
}

sub send_index {
  my ($self, $httpd, $req) = @_;
  my $output = $self->app->render('index');
  $req->respond([200, 'ok', {'Content-Type' => 'text/html; charset=utf-8'}, $output]);
}

sub send_logs {
  my ($self, $httpd, $req) = @_;
  $self->app->logger->refresh_channels(sub {
    my $output = $self->app->render('logs', $self->app->logger);
    $req->respond([200, 'ok', {'Content-Type' => 'text/html; charset=utf-8'}, $output]);
  });
}

sub send_search {
  my ($self, $httpd, $req) = @_;
  my $results = $self->app->logger->search($req->vars, sub {
    my $rows = shift;
    my $content = $self->app->render('results', @$rows);
    $req->respond([200, 'ok', {'Content-Type' => 'text/html; charset=utf-8'},
      $content]);
  });
}

sub send_config {
  my ($self, $httpd, $req) = @_;
  $self->log_debug("serving config");
  my $output = $self->app->render('servers');
  $req->respond([200, 'ok', {}, $output]);
}

sub server_config {
  my ($self, $httpd, $req) = @_;
  $self->log_debug("serving blank server config");
  my $name = $req->parm('name');
  my $config = $self->app->render('new_server', $name);
  my $listitem = $self->app->render('server_listitem', $name);
  $req->respond([200, 'ok', {"Cache-control" => "no-cache"}, 
                to_json({config => $config, listitem => $listitem})]);
}

sub save_config {
  my ($self, $httpd, $req) = @_;
  $self->log_debug("saving config");
  my $new_config = {servers => {}};
  my %params = $req->vars;
  for my $name (keys %params) {
    next unless $params{$name};
    if ($name =~ /^(.+?)_(.+)/) {
      if ($2 eq "channels" or $2 eq "on_connect") {
        if (ref $params{$name} eq "ARRAY") {
          $new_config->{servers}{$1}{$2} = $params{$name};
        }
        else {
          $new_config->{servers}{$1}{$2} = [$params{$name}];
        }
      }
      else {
        $new_config->{servers}{$1}{$2} = $params{$name};
      }
    }
    else {
      $new_config->{$name} = $params{$name};
    }
  }
  $self->config->merge($new_config);
  $self->app->reload_config();
  $self->config->write;
  $req->respond([200, 'ok'])
}

sub tab_order  {
  my ($self, $httpd, $req) = @_;
  $self->log_debug("updating tab order");
  my %vars = $req->vars;
  $self->app->tab_order([
    grep {defined $_} @{$vars{tabs}}
  ]);
  $req->respond([200,'ok']);
}

sub not_found  {
  my ($self, $req) = @_;
  $req->respond([404,'not found']);
}

sub log_debug {
  my $self = shift;
  return unless $self->config->show_debug and @_;
  print STDERR join " ", @_ if $self->config->show_debug;
  print "\n";
}

sub log_info {
  return unless @_;
  print STDERR join " ", @_;
  print STDERR "\n";
}

__PACKAGE__->meta->make_immutable;
1;
