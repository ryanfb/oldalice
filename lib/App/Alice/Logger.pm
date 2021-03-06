package App::Alice::Logger;

use Any::Moose;
use AnyEvent::DBI;
use AnyEvent::IRC::Util qw/filter_colors/;
use SQL::Abstract;

has dbh => (
  is => 'ro',
  isa => 'AnyEvent::DBI',
  lazy => 1,
  default => sub {
    my $self = shift;
    AnyEvent::DBI->new("DBI:SQLite:dbname=".$self->dbfile,"","");
  }
);

has sql => (
  is => 'ro',
  isa => 'SQL::Abstract',
  default => sub {SQL::Abstract->new(cmp => "like")},
);

has dbfile => (
  is => 'ro',
  isa => 'Str',
  required => 1,
);

has channels => (
  is => 'rw',
  isa => 'ArrayRef[Str]',
  lazy => 1,
  default => sub {
    my $self = shift;
    $self->refresh_channels;
    return [];
  }
);

sub BUILD {
  my $self = shift;
  $self->dbh;
  $self->channels;
}

sub log_message {
  my ($self, @fields) = @_;
  $fields[3] = filter_colors($fields[3]);
  my $sth = $self->dbh->exec(
    "INSERT INTO messages (time,nick,channel,body) VALUES(?,?,?,?)"
  , @fields, sub {});
}

sub search {
  my $cb = pop;
  my ($self, %query) = @_;
  %query = map {$_ => "%$query{$_}%"} grep {$query{$_}} keys %query;
  my ($stmt, @bind) = $self->sql->select("messages", '*', \%query, {-desc => 'time'});
  $self->dbh->exec($stmt, @bind, sub {
    my ($db, $rows, $rv) = @_;
    $cb->($rows);
  });
}

sub refresh_channels {
  my ($self, $cb) = @_;
  $self->dbh->exec(
    "SELECT DISTINCT channel FROM messages",
    , (), sub {
      my ($dbh, $rows, $rv) = @_;
      $self->channels([map {$_->[0]} @$rows]);
      $cb->() if $cb;
    }
  );
}

1;
