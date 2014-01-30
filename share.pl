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
    name        => 'Print URLs for new photos',
    description => 'This script polls for new images' .
                   'and prints their URLs and meta information' .
                   'to IRC',
    license     => 'Public Domain',
);


sub handle_photo {
    my ($dir_in, $dir_public, $file) = @_;

    my $filename = "$dir_in/$file";

    my $msg = "";
    my $title = $file;
    if (! -f "/usr/bin/exiftool") {
        print "No exiftool, cannot get image details";
        return;
    }

    my $cmd = "exiftool -f -s -s -s -t -c %.6f -d \"%Y%m%d%H%M\" -ObjectName -Description -GPSPosition -Subject -DateTimeOriginal -FileModifyDate -XMP-photoshop:City -XMP-photoshop:Country $filename";

    # TODO: print URL to IRC even if exiftool fails
    if (!open(EXIF, "$cmd |")) {
        print "Failed to for for exiftool: $!";
        return;
    }

    my $exifout = <EXIF>;
    chomp $exifout;

    close(EXIF);

    my @data = split("\t", $exifout);
    #print $#data;

    # Title
    if ($data[0] ne "-") {
        $data[0] =~ s/\N{U+c383c2a4}/ä/g; # ä
        $data[0] =~ s/\N{U+c383c2b6}/ö/g; # ö 
        $data[0] =~ s/\N{U+c383c2a5}/å/g; # å
        $data[0] =~ s/\N{U+c383c284}/Ä/g; # Ä
        $data[0] =~ s/\N{U+c383c296}/Ö/g; # Ö
        $data[0] =~ s/\N{U+c383c285}/Å/g; # Å
        $msg .= "$data[0]: ";
        $title = $data[0];
        $title =~ s/ /_/g;
        $title =~ s/'//g;
        $title =~ s/ä/a/g;
        $title =~ s/ö/o/g;
        $title =~ s/å/a/g;
        $title =~ s/Ä/A/g;
        $title =~ s/Ö/O/g;
        $title =~ s/Å/A/g;
        $title .= ".jpg";
    }

    # Description
    if ($data[1] ne "-") {
        $msg .= "$data[1]. ";
    }

    # Tags (#something is interpreted as a channel name)
    my @channels = ();
    if ($data[3] ne "-") {
        my @tags = split(", ", $data[3]);
        my @tags_real = ();
        foreach my $t (@tags) {
            if ($t =~ m/^\#/) {
                push(@channels, $t);
            } else {
                push(@tags_real, $t);
            }
        }
        my $tags = join(", ", @tags_real);
        $msg .= "\[$tags\] ";
    }


    # GPS Location, geotags and coordinates
    if ($data[6] ne "-" and $data[7] ne "-") {
        $msg .= "($data[6], $data[7]) ";
    }

    if ($data[2] ne "-") {
        $msg .= "$data[2] ";
    }

    # If title given, prefix file name with create date or if that doesn't exist, with modify date
    if ($data[0] ne "-") {
        if ($data[4] ne "-") {
            $title = "$data[4]_$title";
        } else {
            if ($data[5] ne "-") {
                $title = "$data[5]_$title";
            }
        }
    } else {
        # If no title, suffix file name with something unguessable
        my $dot = rindex($title, ".");
        my $hex = md5_hex(($msg));
        my $random = substr($hex, 0, 4);
        # We just assume the file is ending ".jpg"
        $title =~ s/\.jpg/$random.jpg/g;
    }

    my $orig_title = $title;

    if (-f "/usr/bin/convert") {
        my $cmd = "convert -unsharp 0x2+1+0  -resize 1024 $dir_in/$file $dir_public/$title";

        if (open(CONVERT, "$cmd |")) {
            $orig_title =~ s/\.jpg/_orig.jpg/g;
            close(CONVERT);
        }
    }

    if (!rename("$dir_in/$file", "$dir_public/$orig_title")) {
        print "Failed to rename $dir_in/$file to $dir_public/$orig_title: $!";
        return;
    }

    my $url_prefix = settings_get_str('photos_url_prefix');
    $msg .= "$url_prefix/$title";

    my $channel = settings_get_str('photos_notify_channel');
    if (scalar @channels == 0) {
        push(@channels, $channel);
    }
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

        # TODO: what about videos?
        if (-f "$filename") {
            my $now = time();
            my $date_string = stat($filename)->mtime;
            my $diff = $now - $date_string;

            # Try to ensure that the whole image is there instead of moving 
            # a file that's still being copied.
            if ($diff > 30) {
                handle_photo($dir_in, $dir_public, $file);
            }
        }
    }

    closedir(DIR);
}


settings_add_str('photos', 'photos_dir_incoming',
                 '/path/to/photos_incoming');
settings_add_str('photos', 'photos_dir_public', 
                 '/path/to/www/photos/');
settings_add_str('photos', 'photos_notify_channel', '#test');
settings_add_str('photos', 'photos_url_prefix', 'http://mydomain/photos');

# Let's poll for new images every 5 secs (is this too often?)
timeout_add(5000, "timeouttest", "");
