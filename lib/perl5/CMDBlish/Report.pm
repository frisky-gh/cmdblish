#

package CMDBlish::Report;

use strict;
use Cwd 'abs_path';
use Digest::MD5;

use CMDBlish::Common;


########

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

sub _load_passwd ($) {
	my ($path2content) = @_;
	return {} unless defined $$path2content{"/etc/passwd"};
	my %r;
	foreach my $i ( @{ $$path2content{"/etc/passwd"} } ){
		my ($user, undef, undef, undef, undef, $dir) = split m":", $i;
		$r{$user} = $dir;
	}
	return %r;
}

########

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
		my @d = diff_text $setting_path,
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

	print "[package_versions]\n";
	subcmd_diff_package_versions $old_snapshot, $new_snapshot;
	print "\n";
	print "[package_settings]\n";
	subcmd_diff_package_settings $old_snapshot, $new_snapshot;
	print "\n";
	print "[system_settings]\n";
	subcmd_diff_system_settings  $old_snapshot, $new_snapshot;
	print "\n";

	exit 0;
}

sub _parse_as_crontab ($$$) {
	my ($r, $cronuser, $content) = @_;
	my %env;
	my $lastcomment;
	foreach my $i ( @$content ){
		if( $i =~ m"^\s*$" ){ $lastcomment = undef; next; } 
		if( $i =~ m"^\s*#" ){ $lastcomment = $i; next; }

		if( $i =~ m"^\s*(\w+)=(.*)$" ){ $env{$1} = $2; $lastcomment = undef; next; }

		my ($timing, $user, $cmd);
		if( defined $cronuser ){
			die unless $i =~ m"^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S.*)$";
			my $min     = $1;
			my $hour    = $2;
			my $day     = $3;
			my $month   = $4;
			my $weekday = $5;
			$timing = "$min $hour $day $month $weekday";
			$user   = $cronuser;
			$cmd    = $6;
		}else{
			die unless $i =~ m"^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S.*)$";
			my $min     = $1;
			my $hour    = $2;
			my $day     = $3;
			my $month   = $4;
			my $weekday = $5;
			$timing = "$min $hour $day $month $weekday";
			$user   = $6;
			$cmd    = $7;
		}

		my @env;
		foreach my $j ( sort keys %env ){
			push @env, $j . "=" . $env{$j};
		}
		my $env = join " ", @env;
		
		push @{$$r{$user}}, [ $env, $timing, $cmd, $lastcomment ];
		$lastcomment = undef;
	}
}

sub subcmd_crontab ($) {
	my ($snapshot) = @_;
	my ($host, $time) = snapshot2hosttime $snapshot;
	die unless snapshot_is_present $snapshot;

	my $path2type = {};
	my $path2content = {};
	load_settingcontents $snapshot, $path2type, $path2content;

	my %homedir = _load_passwd $path2content;
	my %crontab;

	# user crontab
	while( my ($user, undef) = each %homedir ){
		foreach my $d ( "/var/spool/cron/$user", "/var/spool/cron/crontabs/$user" ){
			next unless defined $$path2content{$d};
			_parse_as_crontab \%crontab, $user, $$path2content{$d};
		}
	}

	# system crontab
	while( my ($path, $type) = each %$path2type ){
		if    ( $path =~ m"^/etc/crontab$" ){
			_parse_as_crontab \%crontab, undef, $$path2content{$path};
		}elsif( $path =~ m"^/etc/cron.d/(\w[-\w]+)$" ){
			_parse_as_crontab \%crontab, undef, $$path2content{$path};
		}elsif( $path =~ m"^/etc/cron.monthly/(\w[-\w]+)$" ){
			push @{$crontab{'root'}}, [undef, 'monthly', $path];
		}elsif( $path =~ m"^/etc/cron.weekly/(\w[-\w]+)$" ){
			push @{$crontab{'root'}}, [undef, 'weekly',  $path];
		}elsif( $path =~ m"^/etc/cron.daily/(\w[-\w]+)$" ){
			push @{$crontab{'root'}}, [undef, 'daily',   $path];
		}elsif( $path =~ m"^/etc/cron.hourly/(\w[-\w]+)$" ){
			push @{$crontab{'root'}}, [undef, 'hourly',  $path];
		}
	}

	foreach my $user ( sort keys %crontab ){
		my $crontab = $crontab{$user};

		print "$user\n";
		foreach my $i ( sort {$$a[2] cmp $$b[2]} @$crontab ){
			my ($env, $timing, $cmd, $comment) = @$i;
			print "	$cmd\n";
			print "		TIMING	$timing\n";
			print "		ENV	$env\n" unless $env eq "";
			print "		COMMENT	$comment\n" unless $comment eq "";
		}
	}
}

sub subcmd_ssh ($) {
	# 全ホストに対して繰り返す
		# ユーザ名とホームディレクトリの一覧を取得する

	# 全ホストに対して繰り返す
		# システムコンフィグを探す
		# システムコンフィグからユーザコンフィグとIdentityFileとAuthorizedKeysの位置を取得する
		# 全ユーザに対して繰り返す
			# ユーザごとのユーザコンフィグを探す
			# ユーザコンフィグからIdentityFileとAuthorizedKeysの位置を取得する
			# IdentityFileとAuthorizedKeysを取得する

	# 公開鍵->ユーザ@ホスト のマッピングを生成する

	# 全ホストに対して繰り返す
		# 全ユーザに対して繰り返す
			# AuthorizedKeys->ユーザ@ホスト のマッピングを生成する
}

########
no strict;
sub import {
*{caller . "::subcmd_diff"}		= \&subcmd_diff;
*{caller . "::subcmd_crontab"}		= \&subcmd_crontab;
*{caller . "::subcmd_ssh"}		= \&subcmd_ssh;
}
1;

