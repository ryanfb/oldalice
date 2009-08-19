use MooseX::Declare;

=pod

=head1 NAME

Alice - An irc client that can be viewed in any WebKit browser

=cut

=head1 DESCRIPTION

Alice is an IRC client that can run either locally or remotely, and
can view it from multiple browsers at the same time. Alice will
keep a message buffer, so when you load your browser you will get
the last 100 lines from each channel. This way you can close the 
web page and continue to collect messages to be read later.

=head1 NOTIFICATIONS

If you get a message with your nick in the body, and no browsers are
connected, a notification will be sent to either Growl (if you are on
OS X) or using libnotify (on Linux.) Alice does not send any notifications
if a browser is connected, but if you are using Fluid (a Single Site
Browser for OS X), Fluid will send a Growl notification when unfocused.

=head1 RUNNING REMOTELY

Right now there has been very little testing done for running alice
remotely. There is one bug that makes it potentially unusable,
and that only shows up if the server clock is significantly different
from that of the browser's OS. This can be fixed in the future by
calculating an offset and taking that into account.

=cut

class Alice {
  use Alice::Window;
  use Alice::HTTPD;
  use Alice::IRC;
  use MooseX::AttributeHelpers;
  use Digest::CRC qw/crc16/;
  use POE;

  our $VERSION = '0.01';

  has config => (
    is       => 'ro',
    isa      => 'HashRef',
    required => 1,
  );

  has ircs => (
    is      => 'ro',
    isa     => 'HashRef[HashRef]',
    default => sub {{}},
  );

  has httpd => (
    is      => 'ro',
    isa     => 'Alice::HTTPD',
    lazy    => 1,
    default => sub {
      Alice::HTTPD->new(app => shift);
    },
  );

  has dispatcher => (
    is      => 'ro',
    isa     => 'Alice::CommandDispatch',
    default => sub {
      Alice::CommandDispatch->new(app => shift);
    }
  );

  has notifier => (
    is      => 'ro',
    default => sub {
      eval {
        if ($^O eq 'darwin') {
          require Alice::Notifier::Growl;
          Alice::Notifier::Growl->new;
        }
        elsif ($^O eq 'linux') {
          require Alice::Notifier::LibNotify;
          Alice::Notifier::LibNotify->new;
        }
      }
    }
  );

  method dispatch (Str $command, Alice::Window $window) {
    $self->dispatcher->handle($command, $window);
  }

  has window_map => (
    metaclass => 'Collection::Hash',
    isa       => 'HashRef[Alice::Window]',
    default   => sub {{}},
    provides  => {
      values => 'windows',
      set    => 'add_window',
      exists => 'has_window',
      get    => 'get_window',
      delete => 'remove_window',
      keys   => 'window_ids',
    }
  );
  
  method nick_windows (Str $nick) {
    return grep {$_->includes_nick($nick)} $self->windows;
  }

  method buffered_messages (Int $min) {
    return [ grep {$_->{msgid} > $min} map {@{$_->msgbuffer}} $self->windows ];
  }

  method connections {
    return map {$_->connection} values %{$self->ircs};
  }

  method find_or_create_window (Str $title, $connection) {
    my $id = "win_" . crc16(lc($title . $connection->session_alias));
    if (my $window = $self->get_window($id)) {
      return $window;
    }
    my $window = Alice::Window->new(
      title      => $title,
      connection => $connection
    );  
    $self->add_window($id, $window);
  }

  method close_window (Alice::Window $window) {
    return unless $window;
    $self->send($window->close_action);
    $self->log_debug("sending a request to close a tab: " . $window->title)
      if $self->httpd->has_clients;
    $self->remove_window($window->id);
  }

  method add_irc_server (Str $name, HashRef $config) {
    $self->ircs->{$name} = Alice::IRC->new(
      app    => $self,
      alias  => $name,
      config => $config
    );
  }

  method run {
    $self->httpd;
    $self->add_irc_server($_, $self->config->{servers}{$_})
      for keys %{$self->config->{servers}};
    POE::Kernel->run;
  }

  sub send {
    my ($self, @messages) = @_;
    $self->httpd->send(@messages);
    return unless $self->notifier and ! $self->httpd->has_clients;
    for my $message (@messages) {
      $self->notifier->display($message) if $message->{highlight};
    }
  }

  sub log_debug {
    shift;
    print STDERR join(" ", @_) . "\n";
  }
}

=pod

=head1 AUTHORS

Lee Aylward E<lt>leedo@cpan.orgE<gt>

Sam Stephenson

Ryan Baumann

=head1 COPYRIGHT

Copyright 2009 by Lee Aylward E<lt>leedo@cpan.orgE<gt>

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

See L<http://www.perl.com/perl/misc/Artistic.html>

=cut
