package Net::MeoCloud;

use strict;
use warnings;

use URI;
use URI::Escape;
use JSON;
use Net::OAuth; $Net::OAuth::PROTOCOL_VERSION = Net::OAuth::PROTOCOL_VERSION_1_0A;
use LWP::UserAgent;
use LWP::Protocol::https;
use File::Basename 'basename';
use Carp qw/carp cluck/;

=head1 NAME

Net::MeoCloud - A MEO Cloud interface

=head1 VERSION

Version 0.01

=cut

our $VERSION = '0.01';

=head1 SYNOPSYS

This module is a Perl interface to the API for the Portuguese cloud storage
service MEO Cloud. You can learn more about it at L<http://www.meocloud.pt>.

Quick start:

    use Net::MeoCloud;

    my $cloud = Net::MeoCloud->new( key => 'KEY', secret => 'SECRET' );
    $cloud->login;

    # the user manually authorizes the app, retrieving the verifier PIN...

    $cloud->authorize( verifier => $pin );

    my $response = $cloud->share( path => '/Photos/logo.png' );
    my $data = $cloud->get_file( path => '/Photos/logo.png' );

The particular details regarding the API can be found at L<https://meocloud.pt/documentation>

=head1 API

=head2 C<new>

Create a new C<Net::MeoCloud> object. The C<key> and C<secret> parameters are required.

=cut

sub new
{
  my $class = shift;

  my $self = bless { @_ }, $class;

  if ( $self->{key} and $self->{secret} )
  {
    $self->{request_token}  ||= '';
    $self->{request_secret} ||= '';
    $self->{access_token}   ||= '';
    $self->{access_secret}  ||= '';

    $self->{ua}             ||= LWP::UserAgent->new;

    $self->{callback_url}   ||= 'oob',
    $self->{request_url}    ||= 'https://meocloud.pt/oauth/request_token',
    $self->{authorize_url}  ||= 'https://meocloud.pt/oauth/authorize',
    $self->{access_url}     ||= 'https://meocloud.pt/oauth/access_token',

    $self->{root}           ||= 'meocloud'; # or 'sandbox'
    $self->{debug}          ||= $ENV{DEBUG};

    return $self;
  }
  else
  {
    carp "ERROR: Please specify the 'key' and 'secret' parameters.";
  }

  # nok
  return;
}

=head2 C<login>

Perform the initial login operation, identifying the client on the service.

If the handshake is successful, a request token/secret is obtained which allows
an authorization URL to be returned. This URL must be opened by the user to
explicitly authorize access to the service's account.

Furthermore, MEO Cloud then either redirects the user back to the callback URL
(if defined in C<$self-E<gt>{callback_url}>), or openly provides a PIN number
that will be required to verify that the user's authorization is valid.

=cut

sub login
{
  my $self = shift;

  my $request = Net::OAuth->request('request token')->new(
    consumer_key        => $self->{key},
    consumer_secret     => $self->{secret},
    request_url         => $self->{request_url},
    request_method      => 'POST',
    signature_method    => 'HMAC-SHA1',
    timestamp           => time,
    nonce               => $self->_nonce,
    callback            => $self->{callback_url},
    callback_confirmed  => 'true',
  );

  $request->sign;

  my $response = $self->{ua}->post($request->to_url, Content_Type => 'form-data', Content => $request->to_post_body);

  if ( $response->is_success )
  {
    $self->{errstr} = '';

    my $response = Net::OAuth->response('request token')->from_post_body($response->content);
    $self->{request_token}  = $response->token;
    $self->{request_secret} = $response->token_secret;

    cluck "Request Token: '"   . $self->{request_token}   . "'" if ( $self->{debug} );
    cluck "Request Secret: '"  . $self->{request_secret}  . "'" if ( $self->{debug} );

    my $authorize = $self->{authorize_url} . '?oauth_token=' . $self->{request_token};
    $authorize .= '&oauth_callback=' . $self->{callback_url}
      if ( defined $self->{callback_url} and $self->{callback_url} ne 'oob' );

    cluck "Authorization URL: '$authorize'" if ( $self->{debug} );

    # ok
    return $authorize;
  }
  else
  {
    $self->{errstr} = $response->status_line;
    carp 'ERROR: ' . $self->{errstr};
  }

  # nok
  return;
}

=head2 C<authorize>

This method exchanges the request token/secret, obtained after a successful
login, with an access token/secret that is needed for subsequent accesses to
the service's API.

The C<verifier> PIN parameter is required.

=cut

sub authorize
{
  my $self = shift;
  my %args = @_;

  if ( $args{verifier} )
  {
    my $request = Net::OAuth->request('access token')->new(
      consumer_key      => $self->{key},
      consumer_secret   => $self->{secret},
      request_url       => $self->{access_url},
      request_method    => 'POST',
      signature_method  => 'HMAC-SHA1',
      timestamp         => time,
      nonce             => $self->_nonce,
      callback          => $self->{callback_url},
      token             => $self->{request_token},
      token_secret      => $self->{request_secret},
      verifier          => $args{verifier},
    );

    $request->sign;

    my $response = $self->{ua}->post($request->to_url, Content_Type => 'form-data', Content => $request->to_post_body);

    if ( $response->is_success )
    {
      $self->{errstr} = '';

      my $response = Net::OAuth->response('access token')->from_post_body($response->content);
      $self->{access_token}  = $response->token;
      $self->{access_secret} = $response->token_secret;

      cluck "Access Token: '"   . $self->{access_token} . "'"   if ( $self->{debug} );
      cluck "Access Secret: '"  . $self->{access_secret} . "'"  if ( $self->{debug} );

      # ok
      return 1;
    }
    else
    {
      $self->{errstr} = $response->status_line;
      carp 'ERROR: ' . $self->{errstr};
    }
  }
  else
  {
    $self->{errstr} = "Authorization 'verifier' needed.";
    carp 'ERROR: ' . $self->{errstr};
  }

  # nok
  return;
}

=head2 C<is_authorized>

This method returns a boolean answer regarding the authorization status of the current credentials.

    $boolean = $cloud->is_authorized;

=cut

sub is_authorized
{
  my $self = shift;

  my $response = $self->account_info;
  return ($response->{http_response_code} == 200);
}


=head2 C<account_info>

Shows information about the user.

    $data = $cloud->account_info;

=cut

sub account_info
{
  my $self = shift;
  my %args = @_;

  my $endpoint  = 'publicapi';

  my $response = $self->_execute(
    command   => 'Account/Info',
    endpoint  => $endpoint,
    to_url    => $args{to_url} || 0,
  );

  return from_json $response;
}

=head2 C<metadata>

Returns all the metadata available for a given file or folder (specified
through its C<path>).

    $metadata = $cloud->metadata( path => '/Photos' );

=cut

sub metadata
{
  my $self = shift;
  my %args = @_;

  my $path = $args{path};
  delete $args{path};
  my $to_url = $args{to_url} || 0;
  delete $args{to_url};

  my $endpoint  = 'publicapi';
  my $options   = { %args };

  my $response = $self->_execute(
    command   => 'Metadata',
    endpoint  => $endpoint,
    path      => $path,
    root      => $self->{root},
    options   => $options,
    to_url    => $to_url,
  );

  return from_json $response;
}

=head2 C<metadata_share>

Returns the metadata of a shared resource. Its share C<id> and C<name> are
required.

    $data = $cloud->metada_share(
      share_id => 'a1bc7534-3786-40f1-b435-6fv90a00b2a6', name => 'logo.png'
    );

=cut

sub metadata_share
{
  my $self = shift;
  my %args = @_;

  my $endpoint  = 'publicapi';
  my $to_url    = $args{to_url} || 0;
  delete $args{to_url};

  my $options   = { %args };

  delete $options->{id};
  delete $options->{name};

  my $response = $self->_execute(
    command   => 'MetadataShare',
    endpoint  => $endpoint,
    root      => $args{id},
    path      => $args{name},
    options   => $options,
    to_url    => $to_url,
  );

  return from_json $response;
}

=head2 C<list_links>

Returns a list of all the public links created by the user.

    $data = $cloud->list_links;

=cut

sub list_links
{
  my $self = shift;
  my %args = @_;
  my $endpoint = 'publicapi';

  my $response = $self->_execute(
    command   => 'ListLinks',
    endpoint  => $endpoint,
    to_url    => $args{to_url} || 0,
  );

  return from_json $response;
}

=head2 C<delete_link>

Delete a public link of a file or folder. Its share C<id> is required.

    $response = $cloud->delete_link( id => 'a1bc7534-3786-40f1-b435-6fv90a00b2a6' );

=cut

sub delete_link
{
  my $self = shift;
  my %args = @_;

  my $endpoint  = 'publicapi';
  my $method    = 'POST';

  my $response = $self->_execute(
    command   => 'DeleteLink',
    endpoint  => $endpoint,
    method    => $method,
    content   => { shareid => $args{id} },
    to_url    => $args{to_url} || 0,
  );

  return from_json $response;
}

=head2 C<share>

Create a public link of a file or folder. Its C<path> is required.

    $response = $cloud->share( path => '/Photos/logo.png' );

=cut

sub share
{
  my $self = shift;
  my %args = @_;

  my $endpoint  = 'publicapi';
  my $method    = 'POST';

  my $response = $self->_execute(
    command   => 'Shares',
    endpoint  => $endpoint,
    method    => $method,
    root      => $self->{root},
    path      => $args{path},
    to_url    => $args{to_url} || 0,
  );

  return from_json $response;
}

=head2 C<share_folder>

Share a folder with another user. The folder's C<path>, and a target C<email>
are required.

    $response = $cloud->share_folder(
      path => '/Photos', email => 'friend@home.com'
    );

=cut

sub share_folder
{
  my $self = shift;
  my %args = @_;

  my $endpoint  = 'publicapi';
  my $method    = 'POST';

  my $response = $self->_execute(
    command   => 'ShareFolder',
    endpoint  => $endpoint,
    method    => $method,
    root      => $self->{root},
    path      => $args{path},
    content   => { to_email => $args{email} },
    to_url    => $args{to_url} || 0,
  );

  return from_json $response;
}

=head2 C<list_shared_folders>

Returns a list of all the shared folders accessed by the user.

    $data = $cloud->list_shared_folders;

=cut

sub list_shared_folders
{
  my $self = shift;
  my %args = @_;
  my $endpoint = 'publicapi';

  my $response = $self->_execute(
    command   => 'ListSharedFolders',
    endpoint  => $endpoint,
    to_url    => $args{to_url} || 0,
  );

  return from_json $response;
}

=head2 C<list>

Returns metadata for a given file or folder (specified through its C<path>).
Similar to the actual C<metadata> method, but with less items and more options.

    $metadata = $cloud->list( path => '/Photos' );

=cut

sub list
{
  my $self = shift;
  my %args = @_;

  my $path = $args{path} || '';
  delete $args{path};
  my $to_url = $args{to_url} || 0;
  delete $args{to_url};

  my $endpoint  = 'publicapi';
  my $options   = { %args };

  my $response = $self->_execute(
    command   => 'List',
    endpoint  => $endpoint,
    path      => $path,
    root      => $self->{root},
    options   => $options,
    to_url    => $to_url,
  );

  return from_json $response;
}

=head2 C<thumbnail>

Return the thumbnail (in binary format) of the file specified in the C<path>.

    $content = $cloud->thumbnail( path => '/Photos/logo.png' );

=cut

sub thumbnail
{
  my $self = shift;
  my %args = @_;

  my $path = $args{path} || '';
  delete $args{path};
  my $to_url = $args{to_url} || 0;
  delete $args{to_url};

  my $endpoint  = 'api-content';
  my $options   = { %args };

  my $response = $self->_execute(
    command   => 'Thumbnails',
    endpoint  => $endpoint,
    path      => $path,
    root      => $self->{root},
    options   => $options,
    to_url    => $to_url,
  );

  return $response;
}

=head2 C<search>

Search the C<path> for a file, or folder, that matches the given C<query>.

    $content = $cloud->search( path => '/Photos' query => 'logo.png' );

=cut

sub search
{
  my $self = shift;
  my %args = @_;

  my $path = $args{path} || '';
  delete $args{path};
  my $to_url = $args{to_url} || 0;
  delete $args{to_url};

  my $endpoint  = 'publicapi';
  my $options   = { %args };

  my $response = $self->_execute(
    command   => 'Search',
    endpoint  => $endpoint,
    path      => $path,
    root      => $self->{root},
    options   => $options,
    to_url    => $to_url,
  );

  return from_json $response;
}

=head2 C<revisions>

Obtain information of the most recent version on the file in the C<path>.

    $content = $cloud->search( path => '/Photos/logo.png' );

=cut

sub revisions
{
  my $self = shift;
  my %args = @_;

  my $path = $args{path} || '';
  delete $args{path};
  my $to_url = $args{to_url} || 0;
  delete $args{to_url};

  my $endpoint  = 'publicapi';
  my $options   = { %args };

  my $response = $self->_execute(
    command   => 'Revisions',
    endpoint  => $endpoint,
    path      => $path,
    root      => $self->{root},
    options   => $options,
    to_url    => $to_url,
  );

  return from_json $response;
}

=head2 C<restore>

Restore a specific C<revision> of the file in the C<path>.

    $response = $cloud->restore(
      path     => '/Photos/logo.png',
      revision => '384186e2-31e9-11e2-927c-e0db5501ca40'
    );

=cut

sub restore
{
  my $self = shift;
  my %args = @_;

  my $method = 'POST';
  my $path = $args{path} || '';

  my $endpoint  = 'publicapi';

  my $response = $self->_execute(
    command   => 'Restore',
    endpoint  => $endpoint,
    method    => $method,
    path      => $path,
    root      => $self->{root},
    content   => { rev => $args{revision} },
    to_url    => $args{to_url} || 0,
  );

  return from_json $response;
}

=head2 C<media>

Return a direct link for the file in the C<path>. If it's a video/audio file, a
streaming link is returned per the C<protocol> parameter.

    $response = $cloud->media( path => '/Music/song.mp3', protocol => 'rtsp' );

=cut

sub media
{
  my $self = shift;
  my %args = @_;

  my $method = 'POST';
  my $path = $args{path} || '';
  delete $args{path};
  my $to_url = $args{to_url} || 0;
  delete $args{to_url};

  my $endpoint  = 'publicapi';
  my $options   = { %args };

  my $response = $self->_execute(
    command   => 'Media',
    endpoint  => $endpoint,
    method    => $method,
    path      => $path,
    root      => $self->{root},
    content   => $options,
    to_url    => $to_url,
  );

  return from_json $response;
}

=head2 C<delta>

List the current changes available for syncing.

    $data = $cloud->delta;

=cut

sub delta
{
  my $self = shift;
  my %args = @_;

  my $to_url = $args{to_url} || 0;
  delete $args{to_url};

  my $method    = 'POST';
  my $endpoint  = 'publicapi';
  my $options   = { %args };

  my $response = $self->_execute(
    command   => 'Delta',
    endpoint  => $endpoint,
    method    => $method,
    content   => $options,
    to_url    => $to_url,
  );

  return from_json $response;
}

=head2 C<put_file>

Upload a file to MEO Cloud.
You can choose to C<overwrite> it (this being either C<true> or C<false>), if
it already exists, as well as choose to overwrite a C<parent_rev> of the file.

    $response = $cloud->put_file( file => 'logo2.png', path => '/Photos' );

=cut

sub put_file
{
  my $self = shift;
  my %args = @_;

  my $method    = 'POST';
  my $endpoint  = 'api-content';

  my $path  = join '/', ( ($args{path} || ''),  basename $args{file} );

  my $content = $args{content};
  unless ( defined $content )
  {
    if ( open my $fh, '<', $args{file} )
    {
      $content = do { local $/; <$fh> };
      close $fh;
    }
    else
    {
      $self->{errstr} = "Unable to open file '" . $args{file} . "'";
      carp 'ERROR: ' . $self->{errstr};
      return;
    }
  }

  my $to_url = $args{to_url} || 0;

  delete $args{path};
  delete $args{file};
  delete $args{to_url};
  delete $args{content};

  my $response = $self->_execute(
    command   => 'Files',
    endpoint  => $endpoint,
    method    => $method,
    path      => $path,
    root      => $self->{root},
    content   => $content,
    options   => { %args },
    to_url    => $to_url,
  );

  return from_json $response;
}

=head2 C<get_file>

Download a file from MEO Cloud. A specific C<rev> can be requested.

    $data = $cloud->get_file( path => '/Photos/logo2.png' );

=cut

sub get_file
{
  my $self = shift;
  my %args = @_;

  my $endpoint  = 'api-content';
  my $path      = $args{path} || '';
  my $to_url    = $args{to_url} || 0;
  delete $args{to_url};

  delete $args{path};

  my $response = $self->_execute(
    command   => 'Files',
    endpoint  => $endpoint,
    path      => $path,
    root      => $self->{root},
    options   => { %args },
    to_url    => $to_url,
  );

  return $response;
}

=head2 C<copy>

From a file in C<from_path>, create a copy in C<to_path>.
Alternatively, instead of C<from_path>, a copy from a file reference can be
done with C<from_copy_ref>. The reference is generated from a previous call to
C<copy_ref>.

    $response = $cloud->copy(
      from_path => '/Photos/logo2.png', to_path => '/Music/cover.png'
    );

=cut

sub copy
{
  my $self = shift;
  my %args = @_;

  my $to_url = $args{to_url} || 0;
  delete $args{to_url};

  my $method    = 'POST';
  my $endpoint  = 'publicapi';

  $args{root} = $self->{root};

  my $response = $self->_execute(
    command   => 'Fileops/Copy',
    method    => $method,
    endpoint  => $endpoint,
    content   => { %args },
    to_url    => $to_url,
  );

  return from_json $response;
}

=head2 C<copy_ref>

Creates, and returns, a copy reference to the file in C<path>.
This can be used to copy that file to another user's MEO Cloud.

    $response = $cloud->copy_ref( path => '/Music/cover.png' );

=cut

sub copy_ref
{
  my $self = shift;
  my %args = @_;

  my $endpoint  = 'publicapi';
  my $path      = $args{path} || '';

  delete $args{path};

  my $response = $self->_execute(
    command   => 'CopyRef',
    endpoint  => $endpoint,
    path      => $path,
    root      => $self->{root},
    to_url    => $args{to_url} || 0,
  );

  return from_json $response;
}

=head2 C<move>

Take a file in C<from_path>, and move it into C<to_path>.

    $response = $cloud->move(
      from_path => '/Photos/logo2.png', to_path => '/Music/cover.png'
    );

=cut

sub move
{
  my $self = shift;
  my %args = @_;

  my $to_url = $args{to_url} || 0;
  delete $args{to_url};

  my $method    = 'POST';
  my $endpoint  = 'publicapi';

  $args{root} = $self->{root};

  my $response = $self->_execute(
    command   => 'Fileops/Move',
    method    => $method,
    endpoint  => $endpoint,
    content   => { %args },
    to_url    => $to_url,
  );

  return from_json $response;
}

=head2 C<create_folder>

Create a folder in C<path>.

    $response = $cloud->create_folder( path => '/Music/Rock' );

=cut

sub create_folder
{
  my $self = shift;
  my %args = @_;

  my $to_url = $args{to_url} || 0;
  delete $args{to_url};

  my $method    = 'POST';
  my $endpoint  = 'publicapi';

  $args{root} = $self->{root};

  my $response = $self->_execute(
    command   => 'Fileops/CreateFolder',
    method    => $method,
    endpoint  => $endpoint,
    content   => { %args },
    to_url    => $to_url,
  );

  return from_json $response;
}

=head2 C<delete>

Delete a file in C<path>.

    $response = $cloud->delete( path => '/Music/cover.png' );

=cut

sub delete
{
  my $self = shift;
  my %args = @_;

  my $to_url = $args{to_url} || 0;
  delete $args{to_url};

  my $method    = 'POST';
  my $endpoint  = 'publicapi';

  $args{root} = $self->{root};

  my $response = $self->_execute(
    command   => 'Fileops/Delete',
    method    => $method,
    endpoint  => $endpoint,
    content   => { %args },
    to_url    => $to_url,
  );

  return from_json $response;
}

=head2 C<undelete>

Undelete a file, or folder, previously removed.

    $response = $cloud->undelete( path => '/Music/cover.png' );

=cut

sub undelete
{
  my $self = shift;
  my %args = @_;

  my $method    = 'POST';
  my $endpoint  = 'publicapi';
  my $path      = $args{path} || '';

  delete $args{path};

  my $response = $self->_execute(
    command   => 'UndeleteTree',
    method    => $method,
    endpoint  => $endpoint,
    path      => $path,
    root      => $self->{root},
    to_url    => $args{to_url} || 0,
  );

  return from_json $response;
}

=head2 C<error>

Return the most recent error message. If the last API request was completed
successfully, this method will return an empty string.

=cut

sub error { shift->{errstr} }

=head1 INTERNAL API

=head2 C<_nonce>

Generate a unique 'nonce' to be used on each request.

=cut

sub _nonce { int( rand 2 ** 32 ) x 2 }

=head2 C<_execute>

Execute a particular API request to the service's protected resources.

=cut

sub _execute
{
  my $self = shift;
  my %args = @_;

  $args{method}   ||= 'GET';
  $args{endpoint} ||= 'publicapi'; # 'api-content'

  # build the request URI
  my @uri_bits = ( 'https://' . $args{endpoint} . '.meocloud.pt/1' );
  push @uri_bits, $args{command};
  push @uri_bits, $args{root} if ( defined $args{root} );
  if ( defined $args{path} )
  {
    $args{path} =~ s/^\/+//g; # remove the leading slash
    $args{path} =~ s/\/{2,}/\//g; # remove possible duplicate slashes

    # RFC 3986 specifies that URI path components not contain unencoded reserved characters
    # A file whose name has chars from the reserved set below needs to have that char escaped

    my @file  = split( '/', $args{path} );

    if (defined $file[-1] ) {
      my $reserved_chars = qr/[ \/ \[ \] ? # @ ! $ & ' ( ) * + , ; : = ]/x;
      $file[-1] =~ s/($reserved_chars)/uri_escape($1)/eg;
    }

    push @uri_bits, ( join '/', @file );
  }

  my $uri = URI->new( join '/', @uri_bits );
  $uri->query_form($args{options}) if scalar keys %{$args{options}};

  my $request = Net::OAuth->request("protected resource")->new(
    consumer_key      => $self->{key},
    consumer_secret   => $self->{secret},
    request_url       => $uri->as_string,
    request_method    => $args{method},
    signature_method  => 'HMAC-SHA1',
    timestamp         => time,
    nonce             => $self->_nonce,
    token             => $self->{access_token},
    token_secret      => $self->{access_secret},
  );

  $request->sign;

  cluck "Executing '" . $args{method} . "' request to: '" . $uri->as_string . "'" if ( $self->{debug} );

  my $response;
  if ( $args{to_url} )
  {
    return to_json {
      method => $args{method},
      url    => $request->to_url,
    };
  }
  elsif ( $args{method} =~ /GET/i )
  {
    $response = $self->{ua}->get($request->to_url);
  }
  else
  {
    if ( defined $args{content} )
    {
      $response = $self->{ua}->post($request->to_url, Content_Type => 'form-data', Content => $args{content});
    }
    else
    {
      $response = $self->{ua}->post($request->to_url);
    }
  }

  if ( $response->is_success and $response->content ne '' )
  {
    $self->{errstr} = '';

    cluck "Response content: '" . $response->content . "'" if ( $self->{debug} );

    my $data;
    eval { $data = from_json($response->content) };

    if ($@) # it's not JSON; could be file content
    {
      return $response->content;
    }

    $data->{http_response_code} = $response->code() if ( ref $data eq 'HASH' );
    return to_json($data);
  }
  else
  {
    return to_json { http_response_code => $response->code };
  }
}

=head1 AUTHOR

Sérgio Bernardino, C<< <code@sergiobernardino.net> >>

=head1 COPYRIGHT & LICENSE

Copyright 2013 Sérgio Bernardino.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.

=cut

1;

