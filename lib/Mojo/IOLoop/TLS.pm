package Mojo::IOLoop::TLS;
use Mojo::Base 'Mojo::EventEmitter';

use Exporter 'import';
use Mojo::File 'path';

# TLS support requires IO::Socket::SSL
use constant HAS_TLS => $ENV{MOJO_NO_TLS}
  ? 0
  : eval 'use IO::Socket::SSL 1.94 (); 1';
use constant READ  => HAS_TLS ? IO::Socket::SSL::SSL_WANT_READ()  : 0;
use constant WRITE => HAS_TLS ? IO::Socket::SSL::SSL_WANT_WRITE() : 0;

has reactor => sub { Mojo::IOLoop->singleton->reactor };

our @EXPORT_OK = ('HAS_TLS');

# To regenerate the certificate run this command (18.04.2012)
# openssl req -new -x509 -keyout server.key -out server.crt -nodes -days 7300
my $CERT = path(__FILE__)->dirname->child('resources', 'server.crt')->to_string;
my $KEY  = path(__FILE__)->dirname->child('resources', 'server.key')->to_string;

sub DESTROY {
  my $self = shift;
  return unless my $reactor = $self->reactor;
  $reactor->remove($self->{handle}) if $self->{handle};
}

sub negotiate {
  my ($self, $args) = (shift, ref $_[0] ? $_[0] : {@_});

  return $self->emit(error => 'IO::Socket::SSL 1.94+ required for TLS support')
    unless HAS_TLS;

  my $tls = {
    SSL_ca_file => $args->{tls_ca}
      && -T $args->{tls_ca} ? $args->{tls_ca} : undef,
    SSL_error_trap         => sub { $self->emit(error => $_[1]) },
    SSL_honor_cipher_order => 1,
    SSL_server             => $args->{server},
    SSL_startHandshake     => 0
  };
  $tls->{SSL_cert_file}   = $args->{tls_cert}    if $args->{tls_cert};
  $tls->{SSL_cipher_list} = $args->{tls_ciphers} if $args->{tls_ciphers};
  $tls->{SSL_key_file}    = $args->{tls_key}     if $args->{tls_key};
  $tls->{SSL_verify_mode} = $args->{tls_verify}  if exists $args->{tls_verify};
  $tls->{SSL_version}     = $args->{tls_version} if $args->{tls_version};

  if ($args->{server}) {
    $tls->{SSL_cert_file} ||= $CERT;
    $tls->{SSL_key_file}  ||= $KEY;
    $tls->{SSL_verify_mode} //= $args->{tls_ca} ? 0x03 : 0x00;
  }
  else {
    $tls->{SSL_hostname}
      = IO::Socket::SSL->can_client_sni ? $args->{address} : '';
    $tls->{SSL_verifycn_scheme} = $args->{tls_ca} ? 'http' : undef;
    $tls->{SSL_verify_mode} //= $args->{tls_ca} ? 0x01 : 0x00;
    $tls->{SSL_verifycn_name} = $args->{address};
  }

  my $handle = $args->{handle};
  return $self->emit(error => $IO::Socket::SSL::SSL_ERROR)
    unless IO::Socket::SSL->start_SSL($handle, %$tls);
  $self->reactor->io($self->{handle}
      = $handle => sub { $self->_tls($handle, $args->{server}) });
}

sub _tls {
  my ($self, $handle, $server) = @_;

  return $self->emit(upgrade => delete $self->{handle})
    if $server ? $handle->accept_SSL : $handle->connect_SSL;

  # Switch between reading and writing
  my $err = $IO::Socket::SSL::SSL_ERROR;
  if    ($err == READ)  { $self->reactor->watch($handle, 1, 0) }
  elsif ($err == WRITE) { $self->reactor->watch($handle, 1, 1) }
}

1;

=encoding utf8

=head1 NAME

Mojo::IOLoop::TLS - Non-blocking TLS handshake

=head1 SYNOPSIS

  use Mojo::IOLoop::TLS;

  # Negotiate TLS
  my $tls = Mojo::IOLoop::TLS->new;
  $tls->on(upgrade => sub {
    my ($tls, $new_handle) = @_;
    ...
  });
  $tls->on(error => sub {
    my ($tls, $err) = @_;
    ...
  });
  $tls->negotiate(handle => $old_handle, server => 1);

  # Start reactor if necessary
  $tls->reactor->start unless $tls->reactor->is_running;

=head1 DESCRIPTION

L<Mojo::IOLoop::TLS> negotiates TLS for L<Mojo::IOLoop>.

=head1 EVENTS

L<Mojo::IOLoop::TLS> inherits all events from L<Mojo::EventEmitter> and can
emit the following new ones.

=head2 upgrade

  $tls->on(connect => sub {
    my ($tls, $handle) = @_;
    ...
  });

Emitted once TLS has been negotiated.

=head2 error

  $tls->on(error => sub {
    my ($tls, $err) = @_;
    ...
  });

Emitted if an error occurs during negotiation, fatal if unhandled.

=head1 ATTRIBUTES

L<Mojo::IOLoop::TLS> implements the following attributes.

=head2 reactor

  my $reactor = $tls->reactor;
  $tls        = $tls->reactor(Mojo::Reactor::Poll->new);

Low-level event reactor, defaults to the C<reactor> attribute value of the
global L<Mojo::IOLoop> singleton.

=head1 METHODS

L<Mojo::IOLoop::TLS> inherits all methods from L<Mojo::EventEmitter> and
implements the following new ones.

=head2 negotiate

  $tls->negotiate(handle => $handle, server => 1);
  $tls->negotiate({handle => $handle, server => 1});

Negotiate TLS.

These options are currently available:

=over 2

=item handle

  handle => $handle

L<IO::Socket::IP> object to negotiate TLS with.

=item server

  server => 1

Negotiate TLS from the server-side, defaults to the client-side.

=item tls_ca

  tls_ca => '/etc/tls/ca.crt'

Path to TLS certificate authority file. Also activates hostname verification on
the client-side.

=item tls_cert

  tls_cert => '/etc/tls/server.crt'
  tls_cert => {'mojolicious.org' => '/etc/tls/mojo.crt'}

Path to the TLS cert file, defaults to a built-in test certificate on the
server-side.

=item tls_ciphers

  tls_ciphers => 'AES128-GCM-SHA256:RC4:HIGH:!MD5:!aNULL:!EDH'

TLS cipher specification string. For more information about the format see
L<https://www.openssl.org/docs/manmaster/apps/ciphers.html#CIPHER-STRINGS>.

=item tls_key

  tls_key => '/etc/tls/server.key'
  tls_key => {'mojolicious.org' => '/etc/tls/mojo.key'}

Path to the TLS key file, defaults to a built-in test key on the server-side.

=item tls_verify

  tls_verify => 0x00

TLS verification mode, defaults to C<0x03> on the server-side and C<0x01> on the
client-side if a certificate authority file has been provided, or C<0x00>.

=item tls_version

  tls_version => 'TLSv1_2'

TLS protocol version.

=back

=head1 CONSTANTS

L<Mojo::IOLoop::TLS> implements the following constants, which can be
imported individually.

=head2 HAS_TLS

TLS is supported with L<IO::Socket::SSL>.

=head1 SEE ALSO

L<Mojolicious>, L<Mojolicious::Guides>, L<http://mojolicious.org>.

=cut
