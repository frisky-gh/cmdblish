#

package CMDBlish::Report;

use strict;
use Cwd 'abs_path';
use Digest::MD5;
use Text::Diff;

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
die if $old_version eq "-" and $new_version eq "-";
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
		my ($user, undef, undef, undef, undef, $dir, $shell) = split m":", $i;
		next if $shell =~ m"^(/usr/sbin|/usr/bin|/sbin|/bin)/(nologin|true|false)$";
		$r{$user} = $dir;
	}
	return %r;
}

sub _parse_as_ssh_config ($) {
	my ($content) = @_;
	my %r = (
		".ssh/id_rsa"		=> 1,
		".ssh/id_dsa"		=> 1,
		".ssh/id_ecdsa"		=> 1,
		".ssh/id_ecdsa_sk"	=> 1,
		".ssh/id_ed25519"	=> 1,
		".ssh/id_ed25519_sk"	=> 1
	);
	return keys %r;
}

sub _parse_as_sshd_config ($) {
	my ($content) = @_;
	my %r = ( ".ssh/authorized_keys" => 1, ".ssh/authorized_keys2" => 1 );
	foreach my $i ( @$content ){
		next unless $i =~ m"^\s*AuthorizedKeysFile\s+(\S.*)$"i;
		%r = ();
		foreach my $j ( split m"\s+", $1 ){ $r{$j} = 1; }
	}
	return keys %r;
}

sub _parse_as_pubkey ($) {
	my ($content) = @_;
	my @r;
	foreach my $i ( @$content ){
		next if $i =~ m"^\s*$";
		next unless $i =~ m"^([-\w]+)\s+(\S+)(?:\s+(\S.*)?)?$";
		my $keytype = $1;
		my $pubkey  = $2;
		my $comment = $3;
		push @r, "$keytype|$pubkey";
	}
	return @r;
}

sub _parse_as_authorized_keys ($) {
	my ($content) = @_;
	my @r;
	foreach my $i ( @$content ){
		next if $i =~ m"^\s*$";
		next unless $i =~ m{^
			\s*
			(?:
				(
					(?:[-\w]+(?:=(?:"[^"]*"|[^\s,"]*))?,)*
					(?:[-\w]+(?:=(?:"[^"]*"|[^\s,"]*))?)
				)
				\s+
			)?
			([-\w]+)\s+(\S+)(?:\s+(\S.*)?)?
		$}x;
		my $options_text = $1;
		my $keytype = $2;
		my $pubkey  = $3;
		my $comment = $4;
		my $shortkey = substr $pubkey, -16;
		my $options;
		if( $options_text ){
			$options = {};
			while( $options_text ){
				$options_text =~ m{^
					([-\w]+)
					(?:=  (?: "([^"]*)"|([^\s,"]*) )  )?
					(,|$)
				}x or die "[$i], [$options_text], stopped";
				my $k = lc $1;
				my $v = $2 // $3;
				$$options{$k} = $v;
				$options_text = $';
			}
		}
		push @r, ["$keytype|$pubkey", "$shortkey|$comment", $options];
	}
	return @r;
}

sub _canonical ($$$) {
	my ($path, $username, $homedir) = @_;
	$path = "$homedir/$path" unless $path =~ m"^/";

	$path =~ s{%u}{$username}g;

	while( $path =~ s{//}{/} ){}
	while( $path =~ s{/\./}{/} ){}
	while( $path =~ s{/([^/]+)/\.\./}{/} ){}
	return $path;
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

	my $old_pkgname2attrname2value = {};
	my $new_pkgname2attrname2value = {};
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
			my @d = diff_text $setting_path,
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
	my $lastcomment = [];
	foreach my $i ( @$content ){
		if( $i =~ m"^\s*$" ){ $lastcomment = []; next; } 
		if( $i =~ m"^\s*#" ){ push @$lastcomment, $i; next; }

		if( $i =~ m"^\s*(\w+)=(.*)$" ){ $env{$1} = $2; $lastcomment = []; next; }

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
		$lastcomment = [];
	}
}

our @CRONBASEDIR = ( "/var/spool/cron", "/var/spool/cron/crontabs" );

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
		foreach my $b ( @CRONBASEDIR ){
			my $d = "$b/$user";
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
			push @{$crontab{'root'}}, [undef, 'monthly', $path, []];
		}elsif( $path =~ m"^/etc/cron.weekly/(\w[-\w]+)$" ){
			push @{$crontab{'root'}}, [undef, 'weekly',  $path, []];
		}elsif( $path =~ m"^/etc/cron.daily/(\w[-\w]+)$" ){
			push @{$crontab{'root'}}, [undef, 'daily',   $path, []];
		}elsif( $path =~ m"^/etc/cron.hourly/(\w[-\w]+)$" ){
			push @{$crontab{'root'}}, [undef, 'hourly',  $path, []];
		}
	}

	foreach my $user ( sort keys %crontab ){
		my $crontab = $crontab{$user};

		print "$user\n";
		foreach my $i ( sort {$$a[2] cmp $$b[2]} @$crontab ){
			my ($env, $timing, $cmd, $comments) = @$i;
			my @comments = @$comments < 5 ? @$comments : splice @$comments, -5;
			print "	$cmd\n";
			print "		TIMING	$timing\n";
			print "		ENV	$env\n" unless $env eq "";
			foreach my $comment ( @comments ){
				print "		COMMENT	$comment\n";
			}
		}
	}
}

our @SSH_SYSTEMCONFIG  = ( "/etc/ssh/ssh_config" );
our @SSHD_SYSTEMCONFIG = ( "/etc/ssh/sshd_config" );

sub subcmd_ssh (@) {
	my (@snapshots) = @_;

	my %pubkey2userhosts;
	my %userhost2authorizedkeys;

	foreach my $snapshot ( @snapshots ){
		my ($host, $time) = snapshot2hosttime $snapshot;
		die "$snapshot: not found, stopped"
			unless snapshot_is_present $snapshot;

		my $path2type = {};
		my $path2content = {};
		load_settingcontents $snapshot, $path2type, $path2content;

		my %user2homedir = _load_passwd $path2content;
		
		my @identities;
		my @authorizedkeys;
		foreach my $f ( @SSH_SYSTEMCONFIG ){
			next unless defined $$path2content{$f};
			@identities = _parse_as_ssh_config $$path2content{$f};
		}
		foreach my $f ( @SSHD_SYSTEMCONFIG ){
			next unless defined $$path2content{$f};
			@authorizedkeys = _parse_as_sshd_config $$path2content{$f};
		}

		while( my ($user, $homedir) = each %user2homedir ){
			my $userhost = "$user\@$host";
			foreach my $i ( @identities ){
				my $f = _canonical "$i.pub", $user, $homedir;
				next unless defined $$path2content{$f};

				my @pubkey = _parse_as_pubkey $$path2content{$f};
				foreach my $i ( @pubkey ){
					push @{$pubkey2userhosts{$i}}, $userhost;
				}
			}
			foreach my $i ( @authorizedkeys ){
				my $f = _canonical $i, $user, $homedir;
				next unless defined $$path2content{$f};

				my @authorized_keys = _parse_as_authorized_keys $$path2content{$f};
				push @{$userhost2authorizedkeys{$userhost}}, @authorized_keys;
			}
		}
	}

	my %login;
	foreach my $dst_userhost ( sort keys %userhost2authorizedkeys ){
		my $authorizedkeys = $userhost2authorizedkeys{$dst_userhost};
		my %src_userhost;
		foreach my $keyinfo ( @$authorizedkeys ){
			my ($pubkey, $comment, $options) = @$keyinfo;
			my $src_userhosts = $pubkey2userhosts{$pubkey};
			if( $src_userhosts ){
				foreach my $src_userhost ( @$src_userhosts ){
					$src_userhost{$src_userhost} = $options;
				}
			}else{
				$src_userhost{"UNKNOWN($comment)"} = $options;
			}
		}

		foreach my $src_userhost ( keys %src_userhost ){
			my $options = $src_userhost{$src_userhost};
			unless( $options ){
				push @{$login{$src_userhost}}, $dst_userhost;
				next;
			}
			my @options;
			foreach my $k ( sort keys %$options ){
				my $v = $$options{$k};
				if( $v ne "" ){
					push @options, $k.'="'.$v.'"';
				}else{
					push @options, $k;
				}
			}
			my $dst_userhost_option = $dst_userhost
				. "\t" . join ",", @options;
			push @{$login{$src_userhost}}, $dst_userhost_option;
		}
	}

	foreach my $src_userhost ( sort keys %login ){
		foreach my $dst_userhost ( @{$login{$src_userhost}} ){
			print "$src_userhost => $dst_userhost\n";
		}
	}
}

########
no strict;
sub import {
*{caller . "::subcmd_diff"}		= \&subcmd_diff;
*{caller . "::subcmd_crontab"}		= \&subcmd_crontab;
*{caller . "::subcmd_ssh"}		= \&subcmd_ssh;
}
1;

