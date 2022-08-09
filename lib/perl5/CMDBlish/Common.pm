#

package CMDBlish::Common;

use strict;
use GDBM_File;
use Cwd 'abs_path';
use IPC::Open2;

########

sub timestamp ($) {
	my ($sec, $min, $hour, $day, $mon, $year) = localtime shift;
	return sprintf "%04d-%02d-%02d_%02d:%02d:%02d", 1900+$year, 1+$mon, $day, $hour, $min, $sec;
}

sub systemordie ($) {
	my ($cmd) = @_;
	my $r = system $cmd;
	my $code          = $r >> 8;
	my $signal        = $r & 127;
	my $has_core_dump = $r & 128;
	return if $code == 0;
	die "cmd=$cmd, code=$code, stopped";
}

sub mkdirordie ($) {
	my ($dir) = @_;
	return if -d $dir;
	mkdir $dir, 0777 ^ umask or do {
		die "$dir: $!: cannot create, stopped";
	};
}

sub systemordie_on_remote ($$$) {
	my ($host, $option, $cmd) = @_;

	if( $$option{become} eq '' ){
		systemordie "ssh root\@$host $cmd";
	}else{
		my $user = $$option{become};
		systemordie "ssh $user\@$host sudo -u root $cmd";
	}
}

sub sendordie ($$$$) {
	my ($host, $option, $src, $dst) = @_;

	if( $$option{become} eq '' ){
		systemordie "rsync -aSx $src root\@$host:$dst";
	}else{
		my $user = $$option{become};
		systemordie "rsync -aSx --rsync-path='sudo -u root rsync' $src $user\@$host:$dst";
	}
}

sub recvordie ($$$$) {
	my ($host, $option, $src, $dst) = @_;

	if( $$option{become} eq '' ){
		systemordie "rsync -aSx root\@$host:$src $dst";
	}else{
		my $user = $$option{become};
		systemordie "rsync -aSx --rsync-path='sudo -u root rsync' $user\@$host:$src $dst";
	}
}

########


########

sub write_timestamp ($$) {
	my ($snapshot, $timestampname) = @_;

	my $timestamp = timestamp time;

	my $f = "$::STATUSDIR/$snapshot/$timestampname.timestamp";
	open my $h, '>', $f or do {
		die "$f: cannot open, stopped";
	};
	print $h $timestamp, "\n";
	close $h;
}

sub read_timestamp ($$) {
	my ($snapshot, $timestampname) = @_;

	my $f = "$::STATUSDIR/$snapshot/$timestampname.timestamp";
	open my $h, '<', $f or do {
		return undef;
	};
	my $timestamp = <$h>;
	chomp $timestamp;
	close $h;
	die unless $timestamp =~ m"^\d{4}-\d{2}-\d{2}_\d{2}:\d{2}:\d{2}$";
	return $timestamp;
}

sub snapshot_is_present ($) {
	my ($snapshot) = @_;
	return defined read_timestamp $snapshot, "creation";
}

sub create_snapshot ($) {
	my ($snapshot) = @_;
	my $d = "$::STATUSDIR/$snapshot";
	mkdirordie $d;
	write_timestamp $snapshot, "creation";
}

sub snapshot_is_latest ($) {
	my ($snapshot) = @_;
	die unless $snapshot =~ m"^([-+.\w+]+)@([-+.\w]+)$";
	my $host = $1;
	my $time = $2;
	my $timestamp = read_timestamp $snapshot, "creation";

	opendir my $h, "$::STATUSDIR" or do {
		die;
	};
	while( my $e = readdir $h ){
		next unless $e =~ m"^([-+.\w+]+)@([-+.\w]+)$";
		next if $e eq $snapshot;
		next unless $1 eq $host;

		my $t = read_timestamp $e, "creation";
		next unless defined $t;
		next if $t lt $timestamp;

		return undef;
	}
	return 1;
}

########

sub pickout_for_targethost_from_glabal_conffile ($$) {
	my ($targethost, $conffile) = @_;

	open my $h, "<", $conffile or do {
		die "$conffile: cannot open, stopped";
	};

	my @settings;
	my $target = undef;
	while( <$h> ){
		chomp;
		next if m"^\s*(#|$)";

		if( m"^===\s+(\S+)\s+===$" ){
			my $re = $1;
			if( $targethost =~ m"^$re$" ){
				$target = 1;
			}else{
				$target = undef;
			}
		}elsif( m"^.+" ){
			push @settings, $_ if $target;
		}else{
			die "$conffile:$.: illegal format, stopped";
		}
	}
	close $h;

	return @settings;
}

sub pickout_for_targethost_from_glabal_conffiles ($$) {
	my ($targethost, $conffile) = @_;

	my @settings;

	my $f = "$::CONFDIR/$conffile";
	if( -f $f ){
		push @settings, pickout_for_targethost_from_glabal_conffile
			$targethost, $f;
	}

	my $d = "$::CONFDIR/$conffile.d";
	if( -d $d ){
		opendir my $h, $d or do {
			die "$d: cannot open, stopped";
		};
		foreach my $i ( sort readdir $h ){
			next if $i =~ m"^\.";
			push @settings, pickout_for_targethost_from_glabal_conffile
				$targethost, "$d/$i";
		}
		closedir $h;
	}

	return @settings;
}

sub write_perhost_conffile ($$@) {
	my ($targethost, $conffile, @settings) = @_;

	my $f = "$::WORKDIR/$targethost/conf/$conffile";
	open my $h, '>', $f or do {
		die "$f: cannot open, stopped";
	};
	foreach my $setting ( @settings ){
		print $h "$setting\n";
	}
	close $h;
}

sub parse_as_keyvalues (@) {
	my %r;
	foreach my $i ( @_ ){
		next if $i =~ m"^\s*(#|$)";
		unless( $i =~ m"^(\w+)=(.*)$" ){
			die;
			next;
		}
		$r{$1} = $2;
	}
	return \%r;
}

sub parse_as_regexplist (@) {
	my @r;
	foreach my $i ( @_ ){
		next if $i =~ m"^\s*(#|$)";
		push @r, qr"^$i$"
	}
	return \@r;
}


########

sub opendb () {
	my %pkgdb;
	my $f = "$::STATUSDIR/pkgdb.gdbm";
	my $mode = GDBM_WRCREAT | GDBM_REPLACE;
	tie %pkgdb, 'GDBM_File' , $f, $mode, 0644 or do {
		die "$f: cannot open, stopped";
	};
	return \%pkgdb;
}

sub closedb ($) {
	my ($pkgdb) = @_;
	untie %$pkgdb;
}

sub update_pkgdb ($$$$) {
	my ($pkgdb, $pkgname, $version, $info) = @_;
	$pkgdb->{"$pkgname $version"} = $info;
}

sub search_pkgdb ($$$) {
	my ($pkgdb, $pkgname, $version, $info) = @_;
	return $pkgdb->{"$pkgname $version"};
}

########

sub snapshot2hosttime ($) {
	unless( $_[0] =~ m"^([-+.\w+]+)@([-+.\w]+)$" ){
		die;
	}
	return $1, $2;
}

sub hosttime2snapshot ($$) {
	return $_[0] . '@' . $_[1];
}

########

no strict;
sub import {
*{caller . "::timestamp"}      = \&timestamp;
*{caller . "::pickout_for_targethost_from_glabal_conffiles"} = \&pickout_for_targethost_from_glabal_conffiles;
*{caller . "::write_perhost_conffile"} = \&write_perhost_conffile;
*{caller . "::mkdirordie"} = \&mkdirordie;
*{caller . "::systemordie"} = \&systemordie;
*{caller . "::sendordie"} = \&sendordie;
*{caller . "::recvordie"} = \&recvordie;
*{caller . "::systemordie_on_remote"} = \&systemordie_on_remote;
*{caller . "::snapshot2hosttime"} = \&snapshot2hosttime;
*{caller . "::hosttime2snapshot"} = \&hosttime2snapshot;
*{caller . "::write_timestamp"}     = \&write_timestamp;
*{caller . "::read_timestamp"}      = \&read_timestamp;
*{caller . "::snapshot_is_present"} = \&snapshot_is_present;
*{caller . "::snapshot_is_latest"}  = \&snapshot_is_latest;
*{caller . "::create_snapshot"}     = \&create_snapshot;
*{caller . "::parse_as_keyvalues"}  = \&parse_as_keyvalues;
*{caller . "::parse_as_regexplist"} = \&parse_as_regexplist;
}

1;

