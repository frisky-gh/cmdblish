#

package CMDBlish::SubCommand;

use strict;
use Cwd 'abs_path';
use Digest::MD5;

use CMDBlish::Common;


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
	my @rules;
	my $last_pkgname;
	my $last_attrname;
	foreach my $i ( @_ ){
		next if $i =~ m"^\s*(#|$)";

		my ($pkgname, $attrname, @values) = split m"\t", $i;
		$last_pkgname  = $pkgname if $pkgname ne "";
		$last_attrname = $attrname if $attrname ne "";
		next unless @values;

		if    ( $last_attrname eq "MODULES" ){
			my ($re) = @values;
			push @rules, [qr"^$re$", $last_pkgname, $last_attrname];
		}elsif( $last_attrname eq "VOLATILES" ){
			my ($re) = @values;
			push @rules, [qr"^$re$", $last_pkgname, $last_attrname];
		}elsif( $last_attrname eq "SETTINGS" ){
			my ($re) = @values;
			push @rules, [qr"^$re$", $last_pkgname, $last_attrname];
		}elsif( $pkgname eq '' && $attrname ne '' ){
			# 値の設定
		}else{
			die "$last_pkgname: unknown attribute name '$last_attrname' was found, stopped";
		}
	}

	return @rules;
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
	die unless snapshot_is_latest $snapshot;

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

	die unless snapshot_is_latest $snapshot;

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

	die unless snapshot_is_latest $snapshot;

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

	die unless snapshot_is_present $snapshot;

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

	die unless snapshot_is_present $snapshot;

	my @rules = _parse_as_userdefined_rules
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
		foreach my $rule ( @rules ){
			my ($re, $pkgname, $attrname) = @$rule;
			next unless $path =~ $re;

			if( defined $last_pkgname ){
			}else{
				push @{$pkgname2attrname2values{$pkgname}->{$attrname}},
	 				[$perm, $uid_gid, $size, $mtime, $path, $symlink];
				return;
			}
                }
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

	die unless snapshot_is_present $snapshot;

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

	die unless snapshot_is_present $snapshot;

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

	my $regexps = parse_as_regexplist
		pickout_for_targethost_from_glabal_conffiles
			$host, "volatiles";

	_foreach_fileinfo $snapshot, sub {
		my ($perm, $uid_gid, $size, $mtime, $path, $symlink) = @_;

		next if defined $volatilefile{$path};
		next if defined $$path2pkgname{$path};

		# search for volatile ones descripted in conffile among the rest of fileinfo not described in pkginfo.
		foreach my $regexp ( @$regexps ){
			next unless $path =~ m/$regexp/;

			$volatilefile{$path} = 'conf/volatiles';
			last;
		}
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

	die unless snapshot_is_present $snapshot;

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

	my $regexps = parse_as_regexplist
		pickout_for_targethost_from_glabal_conffiles
			$host, "settings";

	_foreach_fileinfo $snapshot, sub {
		my ($perm, $uid_gid, $size, $mtime, $path, $symlink) = @_;

		next if defined $settingfile{$path};
		next if defined $$path2pkgname{$path};

		# search for settings descripted in conffile among the rest of fileinfo not described in pkginfo.
		foreach my $regexp ( @$regexps ){
			next unless $path =~ m/$regexp/;

			$settingfile{$path} = 'conf/settings';
			last;
		}
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

	die unless snapshot_is_present $snapshot;

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

	die unless snapshot_is_latest $snapshot;

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

sub subcmd_diff_package_versions ($$) {
	my ($old_snapshot, $new_snapshot) = @_;

	my ($old_host, $old_time) = snapshot2hosttime $old_snapshot;
	my ($new_host, $new_time) = snapshot2hosttime $new_snapshot;
	die unless snapshot_is_present $old_snapshot;
	die unless snapshot_is_present $new_snapshot;

	my ($old_host, $old_time) = snapshot2hosttime $old_snapshot;
	my ($new_host, $new_time) = snapshot2hosttime $new_snapshot;

	die unless snapshot_is_present $old_snapshot;
	die unless snapshot_is_present $new_snapshot;

	my $old_pkgname2attrname2value;
	my $new_pkgname2attrname2value;
	load_pkginfo $old_snapshot, 'whole', {}, $old_pkgname2attrname2value, {};
	load_pkginfo $new_snapshot, 'whole', {}, $new_pkgname2attrname2value, {};

	my %d = _diff_package_version
		$old_pkgname2attrname2value, $new_pkgname2attrname2value;
	foreach my $pkgname ( sort keys %d ){
		my $v = $d{$pkgname};
		my $old_version = $$v[0];
		my $new_version = $$v[1];
		print "$pkgname	$old_version	$new_version\n";
	}
}

sub subcmd_diff_package_settings ($$) {
	my ($old_snapshot, $new_snapshot) = @_;

	my ($old_host, $old_time) = snapshot2hosttime $old_snapshot;
	my ($new_host, $new_time) = snapshot2hosttime $new_snapshot;
	die unless snapshot_is_present $old_snapshot;
	die unless snapshot_is_present $new_snapshot;

	my $old_path2type = {};
	my $old_path2content = {};
	my $new_path2type = {};
	my $new_path2content = {};
	load_settingcontents $old_snapshot, $old_path2type, $old_path2content;
	load_settingcontents $new_snapshot, $new_path2type, $new_path2content;

	my $old_pkgname2attrname2values = {};
	my $new_pkgname2attrname2values = {};
	load_pkginfo $old_snapshot, 'whole', {}, {}, $old_pkgname2attrname2values;
	load_pkginfo $new_snapshot, 'whole', {}, {}, $new_pkgname2attrname2values;

	my @pkgnames = _merge_names
		keys(%$old_pkgname2attrname2values),
		keys(%$new_pkgname2attrname2values);

	require Text::Diff;

	foreach my $pkgname ( @pkgnames ){
		my @setting_paths = _merge_names
			@{$$old_pkgname2attrname2values{$pkgname}->{SETTINGS}},
			@{$$new_pkgname2attrname2values{$pkgname}->{SETTINGS}};

		my @diff;
		foreach my $setting_path ( @setting_paths ){
			my $old_type    = $$old_path2type{$setting_path};
			my $new_type    = $$new_path2type{$setting_path};
			my $old_content = $$old_path2content{$setting_path};
			my $new_content = $$new_path2content{$setting_path};
			my @d = _diff_text $setting_path,
				"$old_snapshot:$setting_path",
				"$new_snapshot:$setting_path",
				$old_type, $new_type,
				$old_content, $new_content;
			next unless @d;
			push @diff, $setting_path;
			foreach my $i ( @d ){ push @diff, "	$i"; }
		}
		next unless @diff;
		print "$pkgname\n";
		foreach my $i ( @diff ){ print "	$i\n"; }
	}
}

sub subcmd_diff_system_settings ($$) {
	my ($old_snapshot, $new_snapshot) = @_;

	my ($old_host, $old_time) = snapshot2hosttime $old_snapshot;
	my ($new_host, $new_time) = snapshot2hosttime $new_snapshot;
	die unless snapshot_is_present $old_snapshot;
	die unless snapshot_is_present $new_snapshot;

	my $old_path2type = {};
	my $old_path2content = {};
	my $new_path2type = {};
	my $new_path2content = {};
	load_settingcontents $old_snapshot, $old_path2type, $old_path2content;
	load_settingcontents $new_snapshot, $new_path2type, $new_path2content;

	my $old_path2pkgname = {};
	my $new_path2pkgname = {};
	my $new_pkgname2attrname2values = {};
	load_pkginfo $old_snapshot, 'whole', $old_path2pkgname, {}, {};
	load_pkginfo $new_snapshot, 'whole', $old_path2pkgname, {}, {};

	my @package_paths = _merge_names
		keys(%$old_path2pkgname), keys(%$new_path2pkgname);
	my @setting_paths = _merge_names
		keys(%$old_path2type), keys(%$new_path2type);

	my %package_paths;
	foreach my $package_path ( @package_paths ){
		$package_paths{$package_path} = 1;
	}
	
	require Text::Diff;

	my @diff;
	foreach my $setting_path ( @setting_paths ){
		next if $package_paths{$setting_path};

		my $old_type    = $$old_path2type{$setting_path};
		my $new_type    = $$new_path2type{$setting_path};
		my $old_content = $$old_path2content{$setting_path};
		my $new_content = $$new_path2content{$setting_path};
		my @d = _diff_text $setting_path,
			"$old_snapshot:$setting_path",
			"$new_snapshot:$setting_path",
			$old_type, $new_type,
			$old_content, $new_content;
		next unless @d;
		push @diff, $setting_path;
		foreach my $i ( @d ){ push @diff, "	$i"; }
	}
	return unless @diff;
	foreach my $i ( @diff ){ print "$i\n"; }
}

sub subcmd_diff ($$) {
	my ($old_snapshot, $new_snapshot) = @_;

	my ($old_host, $old_time) = snapshot2hosttime $old_snapshot;
	my ($new_host, $new_time) = snapshot2hosttime $new_snapshot;
	die unless snapshot_is_present $old_snapshot;
	die unless snapshot_is_present $new_snapshot;

	subcmd_diff_package_versions $old_snapshot, $new_snapshot;
	#subcmd_diff_package_settings $old_snapshot, $new_snapshot;
	subcmd_diff_system_settings  $old_snapshot, $new_snapshot;

	#foreach my $path ( sort keys %r ){
	#	my $v = $r{$path};
	#	my $action = $$v{ACTION};
	#	my $diff   = $$v{DIFF};
	#	print "$path\t$action\n";
	#	if( $diff ){
	#		my $text = join "", @$diff;
	#		foreach my $i ( split "\n", $text ){
	#			print "\t\t$i\n";
	#		}
	#	}
	#}

	exit 0;
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
*{caller . "::subcmd_diff"}              = \&subcmd_diff;
}
1;

