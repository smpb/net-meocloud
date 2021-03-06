#!perl

use strict;
use warnings;

use Test::More;
use File::Spec;
use File::Basename 'dirname';
use IO::Interactive 'is_interactive';
use Regexp::Common 'URI';
use Data::Dumper;

use lib join '/', File::Spec->splitdir(dirname(__FILE__)), '../lib/';

BEGIN
{
  use_ok('Net::MeoCloud');
}

SKIP:
{
  my $key;
  my $secret;
  my $access_token;
  my $access_secret;

  my $auth_file = join '/', File::Spec->splitdir(dirname(__FILE__)), '../etc/auth.cfg';

  if ( -f $auth_file )
  {
    open my $fh, '<', $auth_file;
    my $auth = eval do { local $/; <$fh> };
    close $fh;

    $key           = $auth->{consumer_key};
    $secret        = $auth->{consumer_secret};
    $access_token  = $auth->{access_token};
    $access_secret = $auth->{access_secret};
  }

  unless ( defined $key and defined $secret )
  {
    skip 'Not running on an interactive shell.', 1 unless is_interactive;

    print 'What is your consumer key? ';
    $key = <>; chomp $key;
    print 'What is your consumer secret? ';
    $secret = <>; chomp $secret;
  }

  like($key, '/[-\w\d]+/', 'The key appears to be valid.');
  like($secret, '/\d+/', 'The secret appears to be valid.');

  my $cloud = Net::MeoCloud->new(
      key     => $key,
      secret  => $secret,
      root    => 'sandbox',
    );
  is(ref $cloud, 'Net::MeoCloud', 'got a MEO Cloud interface');

  ok(! $cloud->is_authorized, 'Credentials not yet valid');

  if ($access_token and $access_secret)
  {
    $cloud->{access_token}  = $access_token;
    $cloud->{access_secret} = $access_secret;
  }
  else
  {
    my $url = $cloud->login;
    like($url, "/$RE{URI}{HTTP}{ -scheme => qr{https?} }/", 'The login process returned an auth URL.');

    print "Authorize this test suite here: '$url'\n";
    print 'What is the verifier PIN? ';
    my $pin = <>; chomp $pin;
    like($pin, '/\d{10}/', 'The PIN is a 10-digit number');
    ok($cloud->authorize( verifier => $pin ), 'Authorized');
  }

  ok($cloud->is_authorized, 'Credentials validated');

  my $data;

  $data = $cloud->account_info;
  is(ref $data, 'HASH', 'Got my account info!');
  print Dumper $data;

  $data = $cloud->metadata( path => '/', file_limit => 2 );
  is(ref $data, 'HASH', 'Got metadata from the root.');
  print Dumper $data;

  $data = $cloud->list_links;
  is(ref $data, 'ARRAY', 'Got a list of public links.');
  print Dumper $data;

  my $item = pop @$data;
  my @path = split '/', $item->{path};
  my $name = pop @path;

  $data = $cloud->metadata_share( id => $item->{shareid}, name => $name );
  is(ref $data, 'HASH', 'Got metadata from a shared item.');
  print Dumper $data;

  $data = $cloud->delete_link( id => $item->{shareid} );
  is($data->{http_response_code}, 200, 'An item is no longer publicly shared.');
  print Dumper $data;

  $data = $cloud->shares( path => $item->{path} );
  is(ref $data, 'HASH', 'An item is now publicly shared.');
  print Dumper $data;

  $data = $cloud->list_shared_folders;
  is(ref $data, 'HASH', 'Got a list of shared folders information.');
  print Dumper $data;

  $data = $cloud->list( path => '/', file_limit => 2 );
  is(ref $data, 'HASH', 'Got a list of metadata from the root.');
  print Dumper $data;

  $data = $cloud->delta;
  is(ref $data, 'HASH', 'Got delta info.');
  print Dumper $data;
}

done_testing;
