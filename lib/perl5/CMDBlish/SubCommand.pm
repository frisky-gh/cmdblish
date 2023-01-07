#

package CMDBlish::SubCommand;

use strict;
use Cwd 'abs_path';
use Digest::MD5;

use CMDBlish::Common;

our $REGMARK;

########

sub dereference_symlink ($$) {
	my ($symlink, $dst) = @_;
	my $path;
	if( $dst =~ m"^/" ){
		$path = $dst;
	}elsif( $symlink =~ m"^(/.*)?(/[^/]+)$" ){
		$path = "$1/$dst";
	}else{
		die;
	}

	$path =~ s[^/][];
	$path =~ s[/$][];
	my @e = split m"/", $path;
	my $i = 0;
	while( $i < @e ){
		my $e = $e[$i];
		if    ( $e eq "" ){
			splice @e, $i, 1;
		}elsif( $e eq "." ){
			splice @e, $i, 1;
		}elsif( $e eq ".." ){
			if( $i > 0 ){ splice @e, $i-1, 2; $i--; }
			else{ splice @e, $i, 1; }
		}else{
			$i++;
		}
	}

	my $new_path = join '/', @e;
	$new_path =~ s[/$][];
	$new_path = '/' if $new_path eq '';
	$new_path = "/$new_path";
	return $new_path;
}

sub fix_path ($$) {
	my ($symlinks, $path) = @_;

	$path =~ s[^/][];
	$path =~ s[/$][];
	my @e = split m"/", $path;
	my $p = '';
	while( @e ){
		my $e = shift @e;
		$p = "$p/$e";
		last unless @e;
		next unless defined $$symlinks{$p};
		my $t = dereference_symlink $p, $$symlinks{$p};
		$p = '';
		$t =~ s[^/][];
		$t =~ s[/$][];
		@e = ( split( m"/", $t ), @e );
	}
	return $p;
}

sub fix_paths ($$) {
	my ($symlinks, $paths) = @_;
	return unless defined $paths;

	foreach my $i (@$paths){
		my $j = fix_path $symlinks, $i;
		next if $i eq $j;
		$i = $j;
	}
}

sub complete_tree ($$$) {
	my ($path2pkgname, $parentdir, $path) = @_;
	
	$path =~ s[^/][];
	$path =~ s[/$][];
	my @e = split m"/", $path;
	my $p = '';
	while( @e ){
		my $e = shift @e;
		$p = "$p/$e";
		next if defined $$path2pkgname{$p};
		next if defined $$parentdir{$p};

		$$parentdir{$p} = 1;
	}
}

sub complete_trees ($$$) {
	my ($path2pkgname, $parentdir, $paths) = @_;
	return unless defined $paths;

	foreach my $path (@$paths){
		complete_tree $path2pkgname, $parentdir, $path;
	}
}

########

sub _foreach_fileinfo ($&) {
	my ($host, $sub) = @_;

	my $f = "$::STATUSDIR/$host/fileinfo.tsv";
	open my $h, "<", $f or do {
		die "$f: cannot open, stopped";
	};
	while( <$h> ){
		chomp;
		my ($perm, $uid_gid, $size, $mtime, $path, $symlink) = split m"\t";
		&$sub( $perm, $uid_gid, $size, $mtime, $path, $symlink );
	}
	close $h;
}

sub _parse_as_userdefined_rules (@) {
	my $section = "S000000";
	my %section2pkgname_attrname;
	my %section2regexps;
	my $last_pkgname;
	my $last_attrname;
	foreach my $i ( @_ ){
		next if $i =~ m"^\s*(#|$)";

		my ($pkgname, $attrname, @values) = split m"\t", $i;
		if( $pkgname ne "" ){
			$last_pkgname = $pkgname;
			$last_attrname = undef;
		}
		if( $attrname ne "" && $attrname ne $last_attrname ){
			$last_attrname = $attrname;
			$section++;
			$section2pkgname_attrname{$section} =
				[$last_pkgname, $last_attrname];
		}
		next unless @values;

		if    ( $last_attrname eq "MODULES" ){
			my ($re) = @values;
			push @{ $section2regexps{$section} }, $re;
		}elsif( $last_attrname eq "VOLATILES" ){
			my ($re) = @values;
			push @{ $section2regexps{$section} }, $re;
		}elsif( $last_attrname eq "SETTINGS" ){
			my ($re) = @values;
			push @{ $section2regexps{$section} }, $re;
		}elsif( $pkgname eq '' && $attrname ne '' ){
			# 値の設定
		}else{
			die "$last_pkgname: unknown attribute name '$last_attrname' was found, stopped";
		}
	}

	my @regexps_for_each_section;
	foreach my $section ( keys %section2regexps ){
		my $regexps_of_section = $section2regexps{$section};
		my $regexp_of_section = '(?:' . join('|', @$regexps_of_section) . ')$' . "(*:$section)";
		push @regexps_for_each_section, $regexp_of_section;
	}

	my $regexp_merged_all_regexps = '^(?:' . join('|', @regexps_for_each_section) . ')';
	return qr"$regexp_merged_all_regexps", \%section2pkgname_attrname;
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

########

sub subcmd_get_fileinfo ($) {
	my ($snapshot) = @_;
	my ($host, $time) = snapshot2hosttime $snapshot;
	my @hostoptions = pickout_for_targethost_from_glabal_conffiles 
		$host, "hostoptions";
	my $hostoption = parse_as_keyvalues @hostoptions;

	create_snapshot $snapshot unless snapshot_is_present $snapshot;
	unless( snapshot_is_latest $snapshot ){
		print STDERR "$snapshot: not latest snapshot.\n";
		return;
	}

	remotectl_prepare_local  $host, $hostoption;
	my @settings = pickout_for_targethost_from_glabal_conffiles
		$host, "fileinfo_excludefiles";
	write_perhost_conffile $host, "fileinfo_excludefiles", @settings;

	remotectl_init    $host, $hostoption;
	remotectl_prepare_remote $host, $hostoption;
	remotectl_run     $host, $hostoption, "get_fileinfo";
	write_timestamp $snapshot, "update";

	update_snapshot $snapshot;
}

sub subcmd_get_pkginfo_os ($) {
	my ($snapshot) = @_;
	my ($host, $time) = snapshot2hosttime $snapshot;
	my @hostoptions = pickout_for_targethost_from_glabal_conffiles 
		$host, "hostoptions";
	my $hostoption = parse_as_keyvalues @hostoptions;

	unless( snapshot_is_latest $snapshot ){
		print STDERR "$snapshot: not latest snapshot.\n";
		return;
	}

	remotectl_prepare_local  $host, $hostoption;

	remotectl_init    $host, $hostoption;
	remotectl_prepare_remote $host, $hostoption;
	remotectl_run     $host, $hostoption, "get_pkginfo_rpm";
	remotectl_run     $host, $hostoption, "get_pkginfo_deb";
	remotectl_run     $host, $hostoption, "get_pkginfo_alternatives";
	write_timestamp $snapshot, "update";

	update_snapshot $snapshot;
}

sub subcmd_get_pkginfo_git ($) {
	my ($snapshot) = @_;
	my ($host, $time) = snapshot2hosttime $snapshot;
	my @hostoptions = pickout_for_targethost_from_glabal_conffiles 
		$host, "hostoptions";
	my $hostoption = parse_as_keyvalues @hostoptions;

	unless( snapshot_is_latest $snapshot ){
		print STDERR "$snapshot: not latest snapshot.\n";
		return;
	}

	remotectl_prepare_local  $host, $hostoption;
	my @settings = pickout_for_targethost_from_glabal_conffiles
		$host, "pkginfo_git_excluderepos";
	write_perhost_conffile $host, "pkginfo_git_excluderepos", @settings;

	remotectl_init    $host, $hostoption;
	remotectl_prepare_remote $host, $hostoption;
	remotectl_run     $host, $hostoption, "get_pkginfo_git";
	write_timestamp $snapshot, "update";

	update_snapshot $snapshot;
}

sub subcmd_fix_pkginfo_os ($) {
	my ($snapshot) = @_;
	my ($host, $time) = snapshot2hosttime $snapshot;
	my $hostoption = parse_as_keyvalues
		pickout_for_targethost_from_glabal_conffiles 
			$host, "hostoptions";

	unless( snapshot_is_present $snapshot ){
		print STDERR "$snapshot: not found.\n";
		return;
	}

	# 全部の symlink を取り出す
	my %symlinks;
	_foreach_fileinfo $snapshot, sub {
		my ($perm, $uid_gid, $size, $mtime, $path, $symlink) = @_;
		next if $symlink eq '';
		
		$symlinks{$path} = $symlink;
	};

	my $pkgname2attrname2value = {};
	my $pkgname2attrname2values = {};
	load_pkginfo $snapshot, 'rpm', {},
		$pkgname2attrname2value, $pkgname2attrname2values;
	load_pkginfo $snapshot, 'deb', {},
		$pkgname2attrname2value, $pkgname2attrname2values;
	load_pkginfo $snapshot, 'alternatives', {},
		$pkgname2attrname2value, $pkgname2attrname2values;

	# パス名のディレクトリ部分に symlink を含むものは、含まない絶対パス名に変換する
	while( my ($pkgname, $attrname2values) = each %$pkgname2attrname2values ){
		fix_paths \%symlinks, $$attrname2values{MODULES};
		fix_paths \%symlinks, $$attrname2values{SETTINGS};
		fix_paths \%symlinks, $$attrname2values{VOLATILES};
	}

	# ファイルの親ディレクトリがどこにも含まれておらず
	# 自動的に生成されたものである場合は、親ディレクトリを
	# パッケージ情報 os:autogenerated として追加する
	my $path2pkgname = {};
	while( my ($pkgname, $attrname2values) = each %$pkgname2attrname2values ){
		if( defined $$attrname2values{MODULES} ){
			foreach my $i ( @{$$attrname2values{MODULES}} ){
				$$path2pkgname{$i} = $pkgname;
			}
		}
		if( defined $$attrname2values{SETTINGS} ){
			foreach my $i ( @{$$attrname2values{SETTINGS}} ){
				$$path2pkgname{$i} = $pkgname;
			}
		}
		if( defined $$attrname2values{VOLATILES} ){
			foreach my $i ( @{$$attrname2values{VOLATILES}} ){
				$$path2pkgname{$i} = $pkgname;
			}
		}
	}

	my $parentdir = {};
	while( my ($pkgname, $attrname2values) = each %$pkgname2attrname2values ){
		complete_trees $path2pkgname, $parentdir,
			$$attrname2values{MODULES};
		complete_trees $path2pkgname, $parentdir,
			$$attrname2values{SETTINGS};
		complete_trees $path2pkgname, $parentdir,
			$$attrname2values{VOLATILES};
	}

	$$pkgname2attrname2value {"os:autogenerated"}->{VERSION} = "0.0";
	$$pkgname2attrname2values{"os:autogenerated"}->{MODULES} =
		[ sort keys %$parentdir ];

	# pkginfo_os として統合した情報をファイル出力する
	my $f = "$::STATUSDIR/$snapshot/pkginfo_os.tsv";
	open my $h, '>', $f or do {
		die;
	};
	foreach my $pkgname ( sort keys %$pkgname2attrname2value ){
		my $attrname2value  = $$pkgname2attrname2value {$pkgname};
		my $attrname2values = $$pkgname2attrname2values{$pkgname};
		print $h "$pkgname\n";
		foreach my $attrname ( sort keys %$attrname2value ){
			my $value = $$attrname2value{$attrname};
			print $h "\t$attrname\t$value\n";
		}
		foreach my $attrname ( sort keys %$attrname2values ){
			my $values = $$attrname2values{$attrname};
			next unless defined $values;
			print $h "\t$attrname\n";
			foreach my $i ( sort @$values ){
				print $h "\t\t$i\n";
			}
		}
	}
	close $h;
}

sub subcmd_extract_pkginfo_userdefined ($) {
	my ($snapshot) = @_;
	my ($host, $time) = snapshot2hosttime $snapshot;
	my $hostoption = parse_as_keyvalues
		pickout_for_targethost_from_glabal_conffiles 
			$host, "hostoptions";

	unless( snapshot_is_present $snapshot ){
		print STDERR "$snapshot: not found.\n";
		return;
	}

	my ($regexp, $section2pkg_attr) = _parse_as_userdefined_rules
		pickout_for_targethost_from_glabal_conffiles 
			$host, "pkginfo_userdefined_rules";

	my $path2pkgname = {};
	load_pkginfo $snapshot, "os",  $path2pkgname, {}, {};
	load_pkginfo $snapshot, "git", $path2pkgname, {}, {};

	my %pkgname2attrname2values;
	my %pkgname2attrname2value;
	_foreach_fileinfo $snapshot, sub {
		my ($perm, $uid_gid, $size, $mtime, $path, $symlink) = @_;
		my $last_pkgname = $$path2pkgname{$path};
		return unless $path =~ $regexp;

		my $pkg_attr = $$section2pkg_attr{$REGMARK};
		die unless $pkg_attr;

		my ($pkgname, $attrname) = @$pkg_attr;
		push @{$pkgname2attrname2values{$pkgname}->{$attrname}},
	 		[$perm, $uid_gid, $size, $mtime, $path, $symlink];
	};

	while(my ($pkgname, $attrname2values) = each %pkgname2attrname2values){
		my $level1;
		my $level2;
		foreach my $i ( @{$$attrname2values{MODULES}} ){
	 		my ($perm, $uid_gid, $size, $mtime, $path, $symlink) = @$i;
			$level1 .= "$path\n";
			$level2 .= join("\t", $perm, $uid_gid, $size, $mtime, $path, $symlink) . "\n";
		}
		my $md5 = Digest::MD5->new;
		$md5->reset;
                $md5->add( $level1 );
                my $level1_hash = $md5->digest;
		$level1_hash =~ s{(.)}{ uc unpack('H2', $1) }egs;
		$level1_hash = '0' if $level1 eq '';
		$md5->reset;
                $md5->add( $level2 );
                my $level2_hash = $md5->digest;
		$level2_hash =~ s{(.)}{ uc unpack('H2', $1) }egs;
		$level2_hash = '0' if $level2 eq '';
		
		my $version = substr($level1_hash, 0, 8) . '.' . substr($level2_hash, 0, 8);
		$pkgname2attrname2value{$pkgname}->{VERSION} = $version;
	}
	

	my $f = "$::STATUSDIR/$snapshot/pkginfo_userdefined.tsv";
	open my $h, ">", $f or do {
		die "$f: cannot open, stopped";
	};
	foreach my $pkgname ( sort keys %pkgname2attrname2values ){
		print $h "$pkgname\n";
		my $attrname2value  = $pkgname2attrname2value{$pkgname};
		my $attrname2values = $pkgname2attrname2values{$pkgname};
		foreach my $attrname ( sort keys %$attrname2value ){
			my $value = $$attrname2value{$attrname};
			print $h "\t$attrname\t$value\n";
		}
		foreach my $attrname ( sort keys %$attrname2values ){
			print $h "\t$attrname\n";
			my $values = $$attrname2values{$attrname};
			foreach my $i ( @$values ){
	 			my ($perm, $uid_gid, $size, $mtime, $path, $symlink) = @$i;
				print $h "\t\t$path\n";
			}
		}
	}
	close $h;
}

sub subcmd_extract_pkginfo_whole ($) {
	my ($snapshot) = @_;
	my ($host, $time) = snapshot2hosttime $snapshot;
	my $hostoption = parse_as_keyvalues
		pickout_for_targethost_from_glabal_conffiles 
			$host, "hostoptions";

	unless( snapshot_is_present $snapshot ){
		print STDERR "$snapshot: not found.\n";
		return;
	}

	my $pkgname2attrname2value = {};
	my $pkgname2attrname2values = {};
	load_pkginfo $snapshot, 'os', {},
		$pkgname2attrname2value, $pkgname2attrname2values;
	load_pkginfo $snapshot, 'git', {},
		$pkgname2attrname2value, $pkgname2attrname2values;
	load_pkginfo $snapshot, 'userdefined', {},
		$pkgname2attrname2value, $pkgname2attrname2values;

	# pkginfo_whole として統合した情報をファイル出力する
	my $f = "$::STATUSDIR/$snapshot/pkginfo_whole.tsv";
	open my $h, '>', $f or do {
		die;
	};
	foreach my $pkgname ( sort keys %$pkgname2attrname2value ){
		my $attrname2value  = $$pkgname2attrname2value {$pkgname};
		my $attrname2values = $$pkgname2attrname2values{$pkgname};
		print $h "$pkgname\n";
		foreach my $attrname ( sort keys %$attrname2value ){
			my $value = $$attrname2value{$attrname};
			print $h "\t$attrname\t$value\n";
		}
		foreach my $attrname ( sort keys %$attrname2values ){
			my $values = $$attrname2values{$attrname};
			next unless defined $values;
			print $h "\t$attrname\n";
			foreach my $i ( sort @$values ){
				print $h "\t\t$i\n";
			}
		}
	}
	close $h;
}

sub subcmd_extract_volatiles ($) {
	my ($snapshot) = @_;
	my ($host, $time) = snapshot2hosttime $snapshot;
	my $hostoption = parse_as_keyvalues
		pickout_for_targethost_from_glabal_conffiles 
			$host, "hostoptions";

	unless( snapshot_is_present $snapshot ){
		print STDERR "$snapshot: not found.\n";
		return;
	}

	my %volatilefile;

	my $path2pkgname = {};
	my $pkgname2attrname2values = {};
	load_pkginfo $snapshot, 'whole',
		$path2pkgname, {}, $pkgname2attrname2values;

	# volatile ones descripted in pkginfo are preffered than volatile ones descripted in conffile.
	while( my ($pkgname, $attrname2values) = each %$pkgname2attrname2values ){
		next unless defined $$attrname2values{VOLATILES};
		foreach my $s ( @{$$attrname2values{VOLATILES}} ){
			$volatilefile{$s} = $pkgname;
		}
	}

	my $regexp = parse_as_regexplist
		pickout_for_targethost_from_glabal_conffiles
			$host, "volatiles";

	_foreach_fileinfo $snapshot, sub {
		my ($perm, $uid_gid, $size, $mtime, $path, $symlink) = @_;

		next if defined $volatilefile{$path};
		next if defined $$path2pkgname{$path};

		# search for volatile ones descripted in conffile among the rest of fileinfo not described in pkginfo.
		return unless $path =~ $regexp;

		$volatilefile{$path} = 'conf/volatiles';
	};

	my $f = "$::STATUSDIR/$snapshot/volatiles.tsv";
	open my $h, ">", $f or do {
		die "$f: cannot open, stopped";
	};
	foreach my $i ( sort keys %volatilefile ){
		print $h "$i\n";
	}
	close $h;
}

sub subcmd_extract_settings ($) {
	my ($snapshot) = @_;
	my ($host, $time) = snapshot2hosttime $snapshot;
	my $hostoption = parse_as_keyvalues
		pickout_for_targethost_from_glabal_conffiles 
			$host, "hostoptions";

	unless( snapshot_is_present $snapshot ){
		print STDERR "$snapshot: not found.\n";
		return;
	}

	my %settingfile;

	my $path2pkgname = {};
	my $pkgname2attrname2values = {};
	load_pkginfo $snapshot, 'whole',
		$path2pkgname, {}, $pkgname2attrname2values;

	# settings descripted in pkginfo are preffered than settings descripted in conffile.
	while( my ($pkgname, $attrname2values) = each %$pkgname2attrname2values ){
		next unless defined $$attrname2values{SETTINGS};
		foreach my $s ( @{$$attrname2values{SETTINGS}} ){
			$settingfile{$s} = $pkgname;
		}
	}

	my $regexp = parse_as_regexplist
		pickout_for_targethost_from_glabal_conffiles
			$host, "settings";

	_foreach_fileinfo $snapshot, sub {
		my ($perm, $uid_gid, $size, $mtime, $path, $symlink) = @_;

		next if defined $settingfile{$path};
		next if defined $$path2pkgname{$path};

		# search for settings descripted in conffile among the rest of fileinfo not described in pkginfo.
		return unless $path =~ $regexp;

		$settingfile{$path} = 'conf/settings';
	};

	my $f = "$::STATUSDIR/$snapshot/settings.tsv";
	open my $h, ">", $f or do {
		die "$f: cannot open, stopped";
	};
	foreach my $i ( sort keys %settingfile ){
		print $h "$i\n";
	}
	close $h;
}

sub subcmd_extract_unmanaged ($) {
	my ($snapshot) = @_;
	my ($host, $time) = snapshot2hosttime $snapshot;
	my $hostoption = parse_as_keyvalues
		pickout_for_targethost_from_glabal_conffiles 
			$host, "hostoptions";

	unless( snapshot_is_present $snapshot ){
		print STDERR "$snapshot: not found.\n";
		return;
	}

	my %unmanagedfile;

	my $path2pkgname = {};
	load_pkginfo  $snapshot, 'whole',        $path2pkgname, {}, {};

	load_filelist $snapshot, "settings",     $path2pkgname;
	load_filelist $snapshot, "volatiles",    $path2pkgname;

	_foreach_fileinfo $snapshot, sub {
		my ($perm, $uid_gid, $size, $mtime, $path, $symlink) = @_;

		my $pkgname = $$path2pkgname{$path};
		next if defined $pkgname;

		$unmanagedfile{$path} = 1;
	};

	my $f = "$::STATUSDIR/$snapshot/unmanaged.tsv";
	open my $h, ">", $f or do {
		die "$f: cannot open, stopped";
	};
	foreach my $i ( sort keys %unmanagedfile ){
		print $h "$i\n";
	}
	close $h;
}

sub subcmd_get_pkginfo_other ($) {
	my ($hostname) = @_;

	# OSパッケージについて pkginfo の読み込み
	my $pkgname2attrname2value = {};
	my $pkgname2attrname2values = {};
	load_pkginfo $hostname, 'os', {}, $pkgname2attrname2value, $pkgname2attrname2values;

	foreach my $pkgname ( sort keys %$pkgname2attrname2value ){
		my $attrname2value  = $pkgname2attrname2value->{$pkgname};
		my $attrname2values = $pkgname2attrname2values->{$pkgname};

		# パッケージごとに pkginfo を文字列化 ($info)
		my $pkgversion = $attrname2value->{VERSION};
		my $info;
		foreach my $attrname ( sort keys %$attrname2value ){
			my $value = $attrname2value->{$attrname};
			$info .= "$attrname\t$value\n";
		}
		foreach my $attrname ( sort keys %$attrname2values ){
			$info .= "$attrname\n";
			my $values = $attrname2values->{$attrname};
			foreach my $value ( sort {$a->[4] cmp $b->[4]} @$values ){
				my ($mode, $uid_gid, $size, $mtime, $path, $link) = @$value;
				my $c = sprintf "%s	%s	%d	%d	%s	%s", $mode, $uid_gid, $size, $mtime, $path, $link;
				$info .= "\t$c\n";
			}
		}
	}
}

sub subcmd_get_settingcontents ($) {
	my ($snapshot) = @_;
	my ($host, $time) = snapshot2hosttime $snapshot;
	my @hostoptions = pickout_for_targethost_from_glabal_conffiles 
		$host, "hostoptions";
	my $hostoption = parse_as_keyvalues @hostoptions;

	unless( snapshot_is_latest $snapshot ){
		print STDERR "$snapshot: not latest snapshot.\n";
		return;
	}

	remotectl_prepare_local  $host, $hostoption;
	systemordie "rsync -aSx $::STATUSDIR/$snapshot/settings.tsv $::WORKDIR/$host/conf/settings";

	remotectl_init    $host, $hostoption;
	remotectl_prepare_remote $host, $hostoption;
	remotectl_run     $host, $hostoption, "get_settingcontents";
	write_timestamp $snapshot, "update";

	update_snapshot $snapshot;
}

sub subcmd_wrapup ($) {
	my ($snapshot) = @_;
	my ($host, $time) = snapshot2hosttime $snapshot;
	my $hostoption = parse_as_keyvalues
		pickout_for_targethost_from_glabal_conffiles 
			$host, "hostoptions";

	my $pkgname2attrname2values = {};
	my $pkgname2attrname2value = {};
	load_pkginfo $snapshot, 'os',
		{}, $pkgname2attrname2value, $pkgname2attrname2values;
	load_pkginfo $snapshot, 'git',
		{}, $pkgname2attrname2value, $pkgname2attrname2values;
	load_pkginfo $snapshot, 'userdefined',
		{}, $pkgname2attrname2value, $pkgname2attrname2values;

	my $f = "$::STATUSDIR/$snapshot/pkgnames.tsv";
	open my $h, ">", $f or do {
		die "$f: cannot open, stopped";
	};
	foreach my $pkgname ( sort keys %$pkgname2attrname2values ){
		print $h "$pkgname\n";
	}
	close $h;

	my $f = "$::STATUSDIR/$snapshot/pkgversions.tsv";
	open my $h, ">", $f or do {
		die "$f: cannot open, stopped";
	};
	foreach my $pkgname ( sort keys %$pkgname2attrname2values ){
		my $version = $$pkgname2attrname2value{$pkgname}->{VERSION};
		print $h "$pkgname\t$version\n";
	}
	close $h;
}

sub subcmd_gzip ($) {
	my ($snapshot) = @_;

	unless( snapshot_is_present $snapshot ){
		print STDERR "$snapshot: not found.\n";
		return;
	}

	my $r = system "tar czf $::STATUSDIR/$snapshot.tar.gz -C $::STATUSDIR $snapshot";
	if ($r == -1) {
		print "failed to execute: $!\n";
		return;
	}elsif ($r & 127) {
		printf "child died with signal %d, %s coredump\n",
		($r & 127),  ($r & 128) ? 'with' : 'without';
		return;
	}elsif ($r != 0) {
		printf "child exited with value %d\n", $r >> 8;
		return;
	}

	my $r = system "rm -r $::STATUSDIR/$snapshot";
}

sub subcmd_gunzip ($) {
	my ($snapshot) = @_;

	unless( snapshot_is_present $snapshot ){
		print STDERR "$snapshot: not found.\n";
		return;
	}

	my $r = system "tar xzf $::STATUSDIR/$snapshot.tar.gz -C $::STATUSDIR $snapshot";
	if ($r == -1) {
		print "failed to execute: $!\n";
		return;
	}elsif ($r & 127) {
		printf "child died with signal %d, %s coredump\n",
		($r & 127),  ($r & 128) ? 'with' : 'without';
		return;
	}elsif ($r != 0) {
		printf "child exited with value %d\n", $r >> 8;
		return;
	}

	unlink "$::STATUSDIR/$snapshot.tar.gz";
}


########
no strict;
sub import {
*{caller . "::subcmd_get_fileinfo"}      = \&subcmd_get_fileinfo;
*{caller . "::subcmd_get_pkginfo_os"}    = \&subcmd_get_pkginfo_os;
*{caller . "::subcmd_get_pkginfo_git"}   = \&subcmd_get_pkginfo_git;
*{caller . "::subcmd_fix_pkginfo_os"}    = \&subcmd_fix_pkginfo_os;
*{caller . "::subcmd_extract_pkginfo_userdefined"}  = \&subcmd_extract_pkginfo_userdefined;
*{caller . "::subcmd_extract_pkginfo_whole"} = \&subcmd_extract_pkginfo_whole;
*{caller . "::subcmd_extract_settings"}  = \&subcmd_extract_settings;
*{caller . "::subcmd_extract_volatiles"} = \&subcmd_extract_volatiles;
*{caller . "::subcmd_extract_unmanaged"} = \&subcmd_extract_unmanaged;
*{caller . "::subcmd_get_settingcontents"} = \&subcmd_get_settingcontents;
*{caller . "::subcmd_wrapup"}            = \&subcmd_wrapup;
*{caller . "::subcmd_gzip"}              = \&subcmd_gzip;
*{caller . "::subcmd_gunzip"}            = \&subcmd_gunzip;
}
1;

