use strict;
use vars qw($VERSION %IRSSI);

use File::stat;
use Time::localtime;
use URI::Escape;
use Digest::MD5 qw(md5_hex);

use Irssi qw(
    command_bind settings_get_str settings_add_str timeout_add server_find_chatnet
);

$VERSION = '1.00';
%IRSSI = (
  authors     => 'Tuomas Kulve',
  contact     => 'tuomas@kulve.fi',
  name        => 'Share URLs',
  description => 'This script polls for new info to share' .
  'and prints their URLs and meta information' .
  'to IRC',
  license     => 'Public Domain',
    );

sub handle_meta {
  my ($dir_in, $dir_public, $file) = @_;

  if (!open(META, "$dir_in/$file")) {
    print "Failed to open $dir_in/$file: $!";
    return;
  }

  my $meta = "";
  {
    local $/ = undef;
    $meta = <META>;
  }
  close(META);

  my $comment = $1
      if ($meta =~ /comment=(.*)/);

  my $channels = $1
      if ($meta =~ /channel=(.*)/);

  my $link = $1
      if ($meta =~ /link=(.*)/);

  my $image = $1
      if ($meta =~ /file=(.*)/);

  my $strip = $1
      if ($meta =~ /strip=(.*)/);

  if (not defined $channels) {
    print "Channels not defined!";
    return;
  }

  if (defined $image and length($image) > 0) {
    handle_photo($dir_in, $dir_public, $channels, $image, $strip, $comment);
  } elsif (defined $link and length($link) > 0) {
    handle_link($channels, $link, $comment);
  } else {
    print "Invalid meta, neither link or image defined";
    return;
  }
}


sub handle_photo {
  my ($dir_in, $dir_public, $channels, $file, $strip, $comment) = @_;

  my $filename = "$dir_in/$file";

  my $msg = "";

  # Suffix file name with something unguessable
  my $dot = rindex($file, ".");
  my $hex = md5_hex($comment);
  my $unguessable = substr($hex, 0, 4);

  my $extension = substr($file, $dot);
  my $base = substr($file, 0, $dot);
  my $name_public = "$base$unguessable$extension";
  my $name_public_orig = "$base${unguessable}_orig$extension";

  my $rotate = 0;
  # Get image rotation from exif
  if ( -e "/usr/bin/exiftool") {
    my $cmd = "exiftool -s -s -s -Orientation -n $filename";
    if (open(EXIF, "$cmd |")) {
      my $exifout = <EXIF>;
      close(EXIF);
      chomp $exifout;

      if ("$exifout" eq "6") {
        $rotate = 90;
      }
    }
  }

  # Resize and optionally rotate the image
  if (-e "/usr/bin/convert") {
    my $cmd = "convert -resize 1024 -rotate $rotate -unsharp 0x2+1+0 $dir_in/$file $dir_public/$name_public";
    if (open(CONVERT, "$cmd |")) {
      close(CONVERT);
    }

    # Remove rotation from exif
    if ($rotate) {
      $cmd = "exiftool -q -q -Orientation=1 -n $dir_public/$name_public";
      if (open(EXIF, "$cmd |")) {
        close(EXIF);
      }
    }
  } else {
    # Without convert there is only one file.
    $name_public_orig = $name_public;
  }

  # Move original in the public tree as well
  if (!rename("$dir_in/$file", "$dir_public/$name_public_orig")) {
    print "Failed to rename $dir_in/$file to $dir_public/$name_public_orig: $!";
    return;
  }

  $msg .= "$comment "
      if (defined $comment and length($comment) > 0);

  my $url_prefix = settings_get_str('photos_url_prefix');
  $msg .= "$url_prefix/$name_public";

  my @channels = split(';', $channels);

  foreach my $c (@channels) {
    my $channel_obj = Irssi::channel_find($c);
    if (defined $channel_obj) {
      my $ircserver = $channel_obj->{server};
      $ircserver->command("/msg -channel $c $msg");
    }
  }
  # Debug:
  # print "$msg";
}



sub handle_link {
  my ($channels, $link, $comment) = @_;

  print "handle_link";

  my @channels = split(';', $channels);

  my $msg = "$comment $link";

  foreach my $c (@channels) {

    my $channel_obj = Irssi::channel_find($c);
    if (defined $channel_obj) {
      my $ircserver = $channel_obj->{server};
      $ircserver->command("/msg -channel $c $msg");
    }
  }
}



sub timeouttest {
  my ($data) = @_;

  my $dir_in     = settings_get_str('photos_dir_incoming');
  my $dir_public = settings_get_str('photos_dir_public');

  if (! -d $dir_in) {
    print "Invalid incoming photos dir: $dir_in";
    return;
  }

  if (! -d $dir_public) {
    print "Invalid public photos dir: $dir_public";
    return;
  }

  if (!opendir(DIR, $dir_in)) {
    print "Can't opendir $dir_in: $!";
    return;
  }

  my $file;
  while (defined ($file = readdir(DIR))) {
    my $filename = "$dir_in/$file";
    if (-f $filename) {
      my $now = time();
      my $date_string = stat($filename)->mtime;
      my $diff = $now - $date_string;

      if ($filename =~ /\.meta$/) {
        # Try to ensure that the whole meta file there
        if ($diff > 10) {
          handle_meta($dir_in, $dir_public, $file);
          unlink($filename);
        }
      } else {
        if ($diff > 24*60*60) {
          print "Removing garbage: $dir_in/$file";
          unlink("$dir_in/$file");
        }
      }
    }
  }
  closedir(DIR);
}

settings_add_str('photos', 'photos_dir_incoming',
                 '/path/to/photos_incoming');
settings_add_str('photos', 'photos_dir_public', 
                 '/path/to/www/photos/');
settings_add_str('photos', 'photos_url_prefix', 'http://mydomain/photos');


# Let's poll for new images every 5 secs (is this too often?)
timeout_add(5000, "timeouttest", "");

# Emacs indentatation information
# Local Variables:
# indent-tabs-mode:nil
# tab-width:2
# c-basic-offset:2
# End:
