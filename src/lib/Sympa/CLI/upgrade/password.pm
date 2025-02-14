# -*- indent-tabs-mode: nil; -*-
# vim:ft=perl:et:sw=4

# Sympa - SYsteme de Multi-Postage Automatique
#
# Copyright 2022 The Sympa Community. See the
# AUTHORS.md file at the top-level directory of this distribution and at
# <https://github.com/sympa-community/sympa.git>.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

package Sympa::CLI::upgrade::password;

use strict;
use warnings;
use Digest::MD5;
use English qw(-no_match_vars);
use MIME::Base64 qw();
use Time::HiRes qw(gettimeofday tv_interval);

BEGIN { eval 'use Crypt::CipherSaber'; }

use Conf;
use Sympa::DatabaseManager;
use Sympa::User;

use parent qw(Sympa::CLI::upgrade);

use constant _options =>
    qw(cache|c=s nosavecache oupdateuser limit|l=i dry_run|n debug|d verbose|v);
use constant _args      => qw();
use constant _need_priv => 0;

sub _run {
    my $class   = shift;
    my $options = shift;

    my $usage =
        "Usage: $0 [--dry_run|n] [--debug|d] [--verbose|v] [--config file] [--cache file] [--nosavecache] [--noupdateuser] [--limit|l]\n";
    my $dry_run  = 0;
    my $debug    = 0;
    my $verbose  = 0;
    my $interval = 100;    # frequency at which we notify how things are going

    my $cache;    # cache of previously encountered hashes (default undef)
    my $updateuser = 1;    # update user database (default yes)
    my $savecache  = 1;    # save hash DB if specified (default yes)
    my $limit      = 0;    # number of users to update (default all)
    my $config = Conf::get_sympa_conf();    # config file to use

    $cache      = $options->{'cache'};
    $config     = $options->{'config'} if defined($options->{'config'});
    $debug      = defined($options->{'debug'});
    $verbose    = defined($options->{'verbose'});
    $dry_run    = defined($options->{'dry_run'});
    $savecache  = !defined($options->{'nosavecache'});
    $updateuser = !defined($options->{'noupdateuser'});
    $limit      = $options->{'limit'} || 0;

    STDOUT->autoflush(1);

    #
    # For safety, dry_run disables all modifications
    #
    if ($dry_run) {
        $savecache = $updateuser = 0;
    }

    die 'Error in configuration'
        unless Conf::load($config);

    # Get obsoleted parameter.
    open my $fh, '<', $config or die $ERRNO;
    my ($cookie) =
        grep {defined} map { /\A\s*cookie\s+(\S+)/s ? $1 : undef } <$fh>;
    close $fh;

    my $password_hash = Conf::get_robot_conf('*', 'password_hash');
    my $bcrypt_cost   = Conf::get_robot_conf('*', 'bcrypt_cost');

    #
    # Handle the cache if specfied
    #
    my $hashes         = {};
    my $hashes_changed = 0;

    if (defined($cache) && (-e $cache)) {
        print "Reading precalculated hashes from $cache\n";
        $hashes = read_hashes($cache = $options->{'cache'});
    }

    #
    # Retrieve user records and update each in turn
    #
    print "Recoding password using $password_hash fingerprint.\n";
    $dry_run && print "dry_run: database will *not* be updated.\n";

    my $sdm = Sympa::DatabaseManager->instance
        or die 'Can\'t connect to database';
    my $sth;

    # Check if RC4 decryption required.
    $sth = $sdm->do_prepared_query(
        q{SELECT COUNT(*) FROM user_table WHERE password_user LIKE 'crypt.%'}
    );
    my ($encrypted) = $sth->fetchrow_array;
    if ($encrypted and not $Crypt::CipherSaber::VERSION) {
        die
            "Password seems encrypted while Crypt::CipherSaber is not installed!\n";
    }

    $sth =
        $sdm->do_query(q{SELECT email_user, password_user from user_table});
    unless ($sth) {
        die 'Unable to prepare SQL statement';
    }

    my $total = {};
    my $count = 0;
    my $hash_time;

    while (my $user = $sth->fetchrow_hashref('NAME_lc')) {
        my $clear_password;

        # if a limit is set, only process that many user records (i.e. for testing)
        last if ($limit && (++$count > $limit));

        # Ignore empty passwords
        next
            unless defined $user->{'password_user'}
            and length $user->{'password_user'};

        if ($user->{'password_user'} =~ /^[0-9a-f]{32}/) {
            printf "Password from %s already encoded as md5 fingerprint\n",
                $user->{'email_user'};
            $total->{'md5'}++;
            next;
        }

        if ($user->{'password_user'} =~ /^\$2a\$/) {
            printf "Password from %s already encoded as bcrypt fingerprint\n",
                $user->{'email_user'};
            $total->{'bcrypt'}++;
            next;
        }

        if ($user->{'password_user'} =~ /\Acrypt[.](.*)\z/) {
            # Old style RC4 encrypted password.
            $clear_password =
                _decrypt_rc4_password($user->{'password_user'}, $cookie);
        } else {
            # Old style cleartext password.
            $clear_password = $user->{'password_user'};
        }

        ## do we have a precalculated hash for this user/password/hashtype?

        my $checksum   = checksum($clear_password);
        my $email_user = $user->{'email_user'};
        my $prehash    = $hashes->{$email_user};
        my $newhash;

        if (   defined($hashes->{$email_user})
            && ($hashes->{$email_user}->{'type'} eq $password_hash)
            && ($hashes->{$email_user}->{'checksum'} eq $checksum)) {

            $newhash = $hashes->{$email_user}->{'hash'};
            printf "pre $email_user $newhash\n" if ($debug);
            $total->{'prehashes'}++;

        } else {
            $hashes_changed = 1;
            # track how long it takes (cheap with MD5, expensive with Bcrypt)
            my $starttime = [gettimeofday];
            $newhash =
                Sympa::User::password_fingerprint($clear_password, undef);
            my $elapsed = tv_interval($starttime, [gettimeofday]);

            $total->{'newhash_time'} += $elapsed;
            $total->{'newhashes'}++;

            $hashes->{$email_user} = {
                'email_user' => $email_user,
                'checksum'   => $checksum,
                'type'       => $password_hash,
                'hash'       => $newhash
            };
            printf "new hash $email_user $newhash\n" if ($debug);
        }

        $total->{'updated'}++;

        # notify along the way if in verbose mode. most useful for larger sites
        if ($verbose && (($total->{'updated'} % $interval) == 0)) {
            printf 'Processed %d users', $total->{'updated'};
            if ($total->{'newhashes'}) {
                printf
                    ", %d new hashes in %.3f sec, %.4f sec/hash %.2f hash/sec",
                    $total->{'newhashes'}, $total->{'newhash_time'},
                    $total->{'newhash_time'} / $total->{'newhashes'},
                    $total->{'newhashes'} / $total->{'newhash_time'};
            }
            print "\n";
        }

        ## Updating Db

        next unless ($updateuser);

        unless (
            $sdm->do_prepared_query(
                q{UPDATE user_table
              SET password_user = ?
              WHERE email_user = ?},
                $newhash,
                $user->{'email_user'}
            )
        ) {
            die 'Unable to execute SQL statement';
        }
    }

    $sth->finish();

    # save hashes for later if hash db file is specified
    if (defined($cache) && $savecache && $hashes_changed) {
        printf "Saving hashes in %s\n", $cache;
        save_hashes($cache, $hashes);
    }

    # print a roundup of changes

    foreach my $hash_type ('md5', 'bcrypt') {
        if ($total->{$hash_type}) {
            printf
                "Found in table user %d passwords stored using %s. Did you run Sympa before upgrading?\n",
                $total->{$hash_type}, $hash_type;
        }
    }
    printf
        "Updated %d user passwords in table user_table using $password_hash hashes.\n",
        ($total->{'updated'} || 0);

    if ($total->{'newhashes'}) {
        my $elapsed = $total->{'newhash_time'};
        my $new     = $total->{'newhashes'};
        printf
            "Time required to calculate new %s hashes: %.2f seconds %.5f sec/hash\n",
            $password_hash, $total->{'newhash_time'},
            ($total->{'newhash_time'} / $total->{'newhashes'});
        if ($password_hash eq 'bcrypt') {
            printf "Bcrypt cost setting: %d\n", $bcrypt_cost;
        }
    }

    if ($total->{'prehashes'}) {
        printf
            "Used %d precalculated hashes to reduce compute time.\n",
            $total->{'prehashes'};
    }

    return 1;
}

my $rc4;

# decrypt RC4 encrypted password.
# Old name: Sympa::Tools::Password::decrypt_password().
sub _decrypt_rc4_password {
    my $inpasswd = shift;
    my $cookie   = shift;

    return $inpasswd unless $inpasswd =~ /\Acrypt[.](.*)\z/;
    $inpasswd = $1;

    $rc4 = Crypt::CipherSaber->new($cookie) unless $rc4;
    return $rc4->decrypt(MIME::Base64::decode($inpasswd));
}

#
# Here we use MD5 as a quick way to make sure that a precalculated hash
# is still valid.
#
sub checksum {
    my ($data) = @_;

    return Digest::MD5::md5_hex($data);
}

#
# The hash file format could not be simpler: space separated columns.
#	email_user checksum type hash
#

sub read_hashes {
    my ($f) = @_;
    my $h = {};

    open my $ifh, '<', $f
        or die sprintf "%s: read_hashes: open %s: %s\n", $PROGRAM_NAME, $f,
        $ERRNO;
    while (<$ifh>) {
        chomp $_;
        next if /^$/ or /^#/;    # ignore blank lines/comments
        my ($email, $checksum, $type, $hash) = split(/ /, $_, 4);

        unless ($email and $checksum and $type and $hash) {
            warn sprintf "%s: parse error: %s\n", $PROGRAM_NAME, $_;
            next;
        }
        die sprintf "%s: %s: unsupported hash type %s\n", $PROGRAM_NAME,
            $email, $type
            unless grep { $type eq $_ } qw(md5 bcrypt);

        $h->{$email} = {
            'email_user' => $email,
            'checksum'   => $checksum,
            'type'       => $type,
            'hash'       => $hash
        };
    }
    close $ifh;

    return $h;
}

sub save_hashes {
    my ($f, $h) = @_;

    my $tmpfile = "$f.tmp.$$";

    open my $ofh, '>', $tmpfile
        or die sprintf "%s: save_hashes: open %s: %s\n", $PROGRAM_NAME,
        $tmpfile, $ERRNO;

    # prevent world/group access
    chmod 0600, $tmpfile;

    foreach my $email_user (sort keys %$h) {
        my $u = $h->{$email_user};
        printf $ofh "%s %s %s %s\n",
            $u->{email_user}, $u->{checksum},
            $u->{type},       $u->{hash};
    }
    close $ofh;

    rename($f,       "$f.old");
    rename($tmpfile, $f);
}

1;
__END__

=encoding utf-8

=head1 NAME

sympa-upgrade-password - Upgrading password in database

=head1 SYNOPSIS

  sympa upgrade password [--dry_run|-n] [--debug|d] [--verbose|v] [--config file ] [--cache file] [--nosavecache] [--noupdateuser] [--limit|l number_of_users]

=head1 OPTIONS

=over

=item --dry_run|-n

Shows what will be done but won't really perform the upgrade process.

=item --debug|-d

Print additional debugging information during the upgrade process.

=item --verbose|-v

Print verbose logging messages during the upgrade process.

=item --config FILENAME

Specify the pathname of the file to use as the Sympa configuration file.
Otherwise the system default Sympa configuration file is used.

=item --cache FILENAME

Specify the pathname of a file to store precalculated hashes for reuse on
subsequent runs of the script.

The file is created if it does not already exist.

This option is useful for large sites using intentionally expensive
password hashes such as bcrypt. In that case this script can be run in
advance to precalculate hashes and reduce the time required during the
final upgrade process.

WARNING: since it contains sensitive password data, this file should
be protected as carefully as any other password file, or a database
dump of the Sympa user_table.

=item --nosavecache

Disables updates of the cache. The cache is still consulted if specified with C<--cache>.

=item --noupdateuser

Disables updates of the user_table. Mostly useful when precalculating user
hashes in advance.

=back

=head1 DESCRIPTION

Versions later than 5.4 use one-way hashes instead of symmetric encryption to
store passwords. This script upgrades any symmetric encrypted passwords it finds to one-way hashes.

Versions later than 6.2.26 support bcrypt.

This upgrade requires to rewriting user password entries in the database.
This upgrade IS NOT REVERSIBLE.

=head1 HISTORY

=head2 Password storage

As of Sympa 3.1b.7, passwords may be stored into user table with encrypted
form by reversible RC4.

Sympa 5.4 or later uses MD5 one-way hash function to encode user passwords.

Sympa 6.2.26 or later has optional support for bcrypt.

=head2 Utilities for upgrading passwords

C<sympa.pl --md5_encode_password> appeared on Sympa 6.0.

It was obsoleted by F<upgrade_sympa_password.pl> on Sympa 6.2.

Its function was moved to C<sympa upgrade password> command line
on Sympa 6.2.70.

=cut
