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
	my @regexps;
	foreach my $i ( @_ ){
		next if $i =~ m"^\s*(#|$)";
		push @regexps, $i;
	}
	my $regexp = '^(?:' . join('|', @regexps) . ')$';
	return qr"$regexp";
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

sub _generate_vcpkg_diff ($) {
	my ($new) = @_;
	my ($pkgattrs, $path2attr) = _parse_pkginfotext $new;

	my @diff;
	foreach my $path ( sort keys %$path2attr ){
		my $attr = $path2attr->{$path};
		next unless $attr =~ m"^MODIFIEDVCMODULES:(.*)$";
		push @diff, "$path\t?\t$1";
	}

	return join "\t", @diff;
}

sub _generate_ospkg_diff ($$) {
	my ($orig, $new) = @_;
	my ($orig_pkgattrs, $orig_path2attr) = _parse_pkginfotext $orig;
	my ($new_pkgattrs, $new_path2attr) = _parse_pkginfotext $new;

	my %path2exist;
	while( my($k, undef) = each %$orig_path2attr ){ $path2exist{$k} |= 1; }
	while( my($k, undef) = each %$new_path2attr ){ $path2exist{$k} |= 2; }

	my @diff;
	foreach my $path ( sort keys %path2exist ){
		my $n = $path2exist{$path};
		if    ( $n == 1 ){
			my $orig_attr = $orig_path2attr->{$path};
			push @diff, "$path\t$orig_attr\t-";
		}elsif( $n == 2 ){
			my $new_attr = $new_path2attr->{$path};
			push @diff, "$path\t-\t$new_attr";
		}else{
			my $orig_attr = $orig_path2attr->{$path};
			my $new_attr = $new_path2attr->{$path};
			push @diff, "$path\t$orig_attr\t$new_attr";
		}
	}
	
	return join "\t", @diff;
}

sub _parse_pkginfotext ($) {
	my ($pkginfotext) = @_;

	my %pkgattrs;
	my %path2attr;

	my $last_attr;
	foreach my $item ( split m"\n", $pkginfotext ){
		my ($attr, @value) = split m"\t", $item;
		$last_attr = $attr if $attr ne '';
		next unless @value;

		if    ( $last_attr eq 'SYSTEMMODULES' ){
			my ($mode, $uid_gid, $size, $mtime, $path, $link) = @value;
			$path2attr{$path} = join(":", $last_attr, $mode, $uid_gid, $size, $mtime, $link);
		}elsif( $last_attr eq 'SYSTEMSETTINGS' ){
			my ($mode, $uid_gid, $size, $mtime, $path, $link) = @value;
			$path2attr{$path} = join(":", $last_attr, $mode, $uid_gid, $size, $mtime, $link);
		}elsif( $last_attr eq 'VCMODULES' ){
			my ($mode, $uid_gid, $size, $mtime, $path, $link) = @value;
			$path2attr{$path} = join(":", $last_attr, $mode, $uid_gid, $size, $mtime, $link);
		}elsif( $last_attr eq 'MODIFIEDVCMODULES' ){
			my ($mode, $uid_gid, $size, $mtime, $path, $link) = @value;
			$path2attr{$path} = join(":", $last_attr, $mode, $uid_gid, $size, $mtime, $link);
		}elsif( $last_attr eq 'VERSION' ){
			my ($version) = @value;
			$pkgattrs{$last_attr} = $version;
		}else{
			die;
		}
	}
	return \%pkgattrs, \%path2attr;
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

sub remotectl_init ($$) {
	my ($host, $opt) = @_;
	systemordie_on_remote $host, $opt, "/bin/true";
}

sub remotectl_prepare_local ($$) {
	my ($host, $opt) = @_;
	mkdirordie  "$::WORKDIR/$host";
	mkdirordie  "$::WORKDIR/$host/status";
	mkdirordie  "$::WORKDIR/$host/conf";
	systemordie "chmod go-rwx $::WORKDIR/$host";
	systemordie "rsync -aSx $::LIBDIR/cmdblagent/ $::WORKDIR/$host/";
}

sub remotectl_prepare_remote ($$) {
	my ($host, $opt) = @_;
	systemordie "rsync -aSx $::LIBDIR/cmdblagent/bin/ $::WORKDIR/$host/bin/";
	sendordie $host, $opt, "$::WORKDIR/$host/", ".cmdblagent/";
}

sub remotectl_run ($$$) {
	my ($host, $opt, $cmd) = @_;
	systemordie_on_remote $host, $opt, ".cmdblagent/bin/$cmd";
	recvordie $host, $opt, ".cmdblagent/status/", "$::WORKDIR/$host/status/";
}

sub update_snapshot ($) {
	my ($snapshot) = @_;
	my ($host, $time) = snapshot2hosttime $snapshot;
	mkdirordie "$::STATUSDIR/$snapshot";
	systemordie "rsync -aSx $::WORKDIR/$host/status/ $::STATUSDIR/$snapshot/";
}

sub load_filelist ($$$) {
	my ($snapshot, $listname, $path2listname) = @_;

	my $f = "$::STATUSDIR/$snapshot/$listname.tsv";
	open my $h, "<", $f or do {
		return;
	};
	while( <$h> ){
		chomp;
		$$path2listname{$_} = $listname;
	}
	close $h;
}

########

sub load_pkginfo ($$$$$) {
	my ($snapshot, $pkgtype, $path2pkgname, $pkgname2attrname2value, $pkgname2attrname2values) = @_;

	my $f = "$::STATUSDIR/$snapshot/pkginfo_$pkgtype.tsv";

	my $last_pkgname;
	my $last_attrname;

	open my $h, "<", $f or do {
		return;
	};
	while( <$h> ){
		chomp;
		my ($pkgname, $attrname, @value) = split m"\t";
		$last_pkgname = $pkgname if $pkgname ne "";
		$last_attrname = $attrname if $attrname ne "";
		next unless @value;

		if    ( $last_attrname eq "MODULES" ){
			my $path = $value[0];
			push @{ $pkgname2attrname2values->{$last_pkgname}->{MODULES} }, $path;
			$$path2pkgname{$path} = $last_pkgname;
		}elsif( $last_attrname eq "MODIFIEDVCMODULES" ){
			my $path = $value[0];
			push @{ $pkgname2attrname2values->{$last_pkgname}->{MODIFIEDMODULES} }, $path;
			$$path2pkgname{$path} = $last_pkgname;
		}elsif( $last_attrname eq "VOLATILES" ){
			my $path = $value[0];
			push @{ $pkgname2attrname2values->{$last_pkgname}->{VOLATILES} }, $path;
			$$path2pkgname{$path} = $last_pkgname;
		}elsif( $last_attrname eq "SETTINGS" ){
			my $path = $value[0];
			push @{ $pkgname2attrname2values->{$last_pkgname}->{SETTINGS} }, $path;
			$$path2pkgname{$path} = $last_pkgname;
		}elsif( $last_attrname eq "VERSION" ){
			$pkgname2attrname2value->{$last_pkgname}->{VERSION} = $value[0];
			$pkgname2attrname2values->{$last_pkgname} //= {};
		}elsif( $last_attrname eq "OPTIONS" ){
			$pkgname2attrname2value->{$last_pkgname}->{OPTIONS}->{$value[0]} = $value[1];
		}elsif( $last_attrname eq "MODIFIEDMODULES" ){
		}else{
			die "$last_attrname: illegal attribute, stopped";
		}
	}
	close $h;
}

sub load_settingcontents ($$$) {
	my ($snapshot, $path2type, $path2content) = @_;

	my $f = "$::STATUSDIR/$snapshot/settingcontents.tsv";

	my $last_path;
	my $last_attrname;

	open my $h, "<", $f or do {
		die "$f: cannot open, stopped";
	};
	while( <$h> ){
		chomp;
		my @v = split m"\t";
		my ($path, $attrname, @value) = @v;
		$last_path     = $path     if $path     ne "";
		$last_attrname = $attrname if $attrname ne "";

		next if @v < 3;
		if    ( $last_attrname eq "TYPE" ){
			$$path2type{$last_path} = $value[0];

		}elsif( $last_attrname eq "CONTENT" ){
			my $l = join "\t", @value;
			push @{ $$path2content{$last_path} }, $l;

		}else{
			die "$last_attrname: illegal attribute, stopped";
		}
	}
	close $h;
}

sub _merge_names (@) {
	my %r;
	foreach my $i ( @_ ){ $r{$i} = 1; }
	return keys %r;
}

sub _diff_package_version ($$) {
	my ($old, $new) = @_;
	my %d;
	while( my ($k, $v) = each %$old ){ $d{$k} += 1; }
	while( my ($k, $v) = each %$new ){ $d{$k} += 2; }

	my %r;
	while( my ($k, $v) = each %d ){
		my $old_version = $$old{$k}->{VERSION} // '-';
		my $new_version = $$new{$k}->{VERSION} // '-';
		next if $old_version eq $new_version;
		$r{$k} = [ $old_version, $new_version ];
	}
	return %r;
}

sub _diff_path ($$) {
	my ($old, $new) = @_;
	my %r;
	while( my ($k, $v) = each %$old ){ $r{$k} += 1; }
	while( my ($k, $v) = each %$new ){ $r{$k} += 2; }

	my @remove;
	my @add;
	my @comm;
	foreach my $k ( sort keys %r ){
		my $v = $r{$k};
		if   ( $v == 1 ){ push @remove, $k; }
		elsif( $v == 2 ){ push @add,    $k; }
		elsif( $v == 3 ){ push @comm,   $k; }
		else{ die; }
	}
	return \@remove, \@add, \@comm;
}

sub diff_text ($$$$$$$) {
	my ($path, $old_name, $new_name, $old_type, $new_type, $old_content, $new_content) = @_;

	if( $old_type eq "" && $new_type ne "" ){
		return ( "ADDED" );
	}
	if( $old_type ne "" && $new_type eq "" ){
		return ( "REMOVED" );
	}
	unless( $old_type eq $new_type ){
		return ( "CHANGE_TYPE: $old_type => $new_type" );
	}

	my ($old, $new) ;
	$old = join "\n", @$old_content, "" if defined $old_content;
	$new = join "\n", @$new_content, "" if defined $new_content;
	return () if $old eq $new;

	if( $old_type eq "BINARYFILE" ){
		return ( "BINARYFILE MODIFIED" );
	}
	if( $old_type eq "LARGEFILE" ){
		return ( "LARGEFILE MODIFIED" );
	}
	if( $old_type ne "FILE" ){
		return ( "$old_type: $old => $new" );
	}

	my $output;
	my $diff = Text::Diff::diff( \$old, \$new, {
		STYLE => 'Unified',
		FILENAME_A => $old_name,
		FILENAME_B => $new_name,
		CONTEXT => 3,
		OUTPUT => \$output,
	} );
	return split m"\n", $output;
}


########

no strict;
sub import {
*{caller . "::timestamp"}		= \&timestamp;
*{caller . "::pickout_for_targethost_from_glabal_conffiles"} = \&pickout_for_targethost_from_glabal_conffiles;
*{caller . "::write_perhost_conffile"}	= \&write_perhost_conffile;
*{caller . "::mkdirordie"}		= \&mkdirordie;
*{caller . "::systemordie"}		= \&systemordie;
*{caller . "::sendordie"}		= \&sendordie;
*{caller . "::recvordie"}		= \&recvordie;
*{caller . "::systemordie_on_remote"}	= \&systemordie_on_remote;
*{caller . "::snapshot2hosttime"}	= \&snapshot2hosttime;
*{caller . "::hosttime2snapshot"}	= \&hosttime2snapshot;
*{caller . "::write_timestamp"}		= \&write_timestamp;
*{caller . "::read_timestamp"}		= \&read_timestamp;
*{caller . "::snapshot_is_present"}	= \&snapshot_is_present;
*{caller . "::snapshot_is_latest"}	= \&snapshot_is_latest;
*{caller . "::create_snapshot"}		= \&create_snapshot;
*{caller . "::update_snapshot"}		= \&update_snapshot;
*{caller . "::parse_as_keyvalues"}	= \&parse_as_keyvalues;
*{caller . "::parse_as_regexplist"}	= \&parse_as_regexplist;

*{caller . "::remotectl_init"}		= \&remotectl_init;
*{caller . "::remotectl_prepare_local"} = \&remotectl_prepare_local;
*{caller . "::remotectl_prepare_remote"} = \&remotectl_prepare_remote;
*{caller . "::remotectl_run"}		= \&remotectl_run;

*{caller . "::load_settingcontents"}	= \&load_settingcontents;
*{caller . "::load_pkginfo"}		= \&load_pkginfo;
*{caller . "::load_filelist"}		= \&load_filelist;
*{caller . "::diff_text"}		= \&diff_text;
}
1;

