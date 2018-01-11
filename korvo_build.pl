#!perl
#
#
#  This script builds and optionally tests GTKorvo projects.  What is built and how it is build is controlled by
#  the build_config file.  This file is either supplied on the command line
#  with a -c argument, or searched for in '.', or '$HOME'.  If the korvo_arch script is found, or if a -a
#  argument is specified, then the file 'build_config.$KORVO_ARCH' is
#  prefered.  Alternatively, 'build_config.$HOSTNAME' (where $HOSTNAME is
#  the output of the hostname command) is prefered over simple
#  'build_config'.  By default the script produces a moderate amount of
#  output, which can be suppressed with '-q' or enhanced with '-v'.
#
#  Further documentation can be found in the supplied sample build_config file.
#
use strict;
use warnings;
use Cwd;
use File::Basename;
use File::Spec;
use 5.010;

my $script_pwd = getcwd;

my $enable_testing = 1;
my $verbose = 0;
my $quiet = 0;
my $BUILD_CONFIG = "";
my $enable_debug_build = 0;
my $ARCH = "";
my $build_config_open = 0;
our %korvo_tag;

my ($RESULTS_FILES_DIR, $BUILD_AREA, $EVPATH_TEST_INSTALL_DIR, $VERSION_TAG, $INSTALL_DIRECTORY, @projects);
my (%spec, %tool, %cmake_args, $OVERRIDE_VERSION, $OVERRIDE_DISABLE_TESTING, $stop_on_failure);

$OVERRIDE_DISABLE_TESTING = 0;

until ( ! @ARGV ) {
    $_ = $ARGV[0];
    last if /^--$/;
    if(/^-v/)    { $verbose++ }
    elsif(/^-q/)    { $quiet++;}
    elsif(/^--stop_on_failure/) {$stop_on_failure=1;}
    elsif(/^-a/)    { $ARCH=$ARGV[1];  shift; }
    elsif(/^-V/)    { $OVERRIDE_VERSION=$ARGV[1];  shift; }
    elsif(/^-D/)    { $OVERRIDE_DISABLE_TESTING++; }
    elsif(/^--debug/)    { $enable_debug_build++; }
    elsif(/^-c/)    { $BUILD_CONFIG=$ARGV[1];  shift; }
    else {
	print  "Unknown argument \"$_\"\n";
	print  "Arguments:\n";
	print  "\t -v \t verbose\n";
	print  "\t -q \t quiet\n";
	print  "\t -a <arch> \t what sets the \$ARCH value\n";
	print  "\t --debug \t build with debug (override build_config)\n";
	print  "\t -c <config_file> \t file to use as build_config\n";
	print  "\t -V <version> \t override version spec in build_config\n";
	print  "\t -D \t disable testing (despite spec in build_config)\n";
	print  "\n";
	exit;
    }
    shift;
}

check_needed_commands();

my $HOME = $ENV{'HOME'};
my $USER = $ENV{'USER'};
my $hostname = `hostname`; chop($hostname);
my $korvo_arch_cmd = `which korvo_arch 2>/dev/null`;

if ("$ARCH" eq "") {
  if ($korvo_arch_cmd) {
    $ARCH=`korvo_arch`;
  } else {
    my $dir = dirname $0;
    if (-e "$dir/korvo_arch") {
      if (! -x "$dir/korvo_arch") {
	if (!($quiet != 0)) {
	  print("Doing chmod of korvo_arch\n");
	}
	system("chmod ugo+x $dir/korvo_arch");
      }
      $ARCH=`$dir/korvo_arch`;
    }
  }
  chop($ARCH);
}
$ARCH =~ s/^\s*//g;
$ARCH =~ s/\s*$//g;

my $DOT_ARCH = "";
if ($ARCH ne "" ) { 
    $DOT_ARCH=".$ARCH";
}

my $UNDER_ARCH = `echo $ARCH | tr '.\\055' '__'`;
chop($UNDER_ARCH);
$UNDER_ARCH =~ s/^\s*//g;
$UNDER_ARCH =~ s/\s*$//g;

my @config_path = ('$HOME', '$script_pwd');
my @config_files = ('korvo_build_config.$ARCH', 'korvo_build_config', 'build_config.$ARCH', 'build_config.$USER', 'build_config');
my @config_search;

if (("$BUILD_CONFIG" ne "")  && (!-f "$BUILD_CONFIG")) {
  die ("Build Configuration not found at $BUILD_CONFIG");
}
foreach (@config_files) {
  my $file = $_;
  foreach (@config_path) {
    my $path = $_;
    if ((/ARCH/) && ("$ARCH" eq "")) { next; }
    my $eval_file = eval('"'.$path.'/'.$file.'"'); warn $@ if $@;
    push(@config_search, $eval_file);
  }
}
      
foreach (@config_search) {
    my $eval_file = eval('"'.$_.'"'); warn $@ if $@;
    if (($BUILD_CONFIG eq "") && (-f "$eval_file")) {
      $BUILD_CONFIG=$eval_file;
      last;
    }
}
if ($BUILD_CONFIG eq "") {
  die ("Build configuration not found!\n\tSearch path: @config_search\n");
}

open(CONFIG, "$BUILD_CONFIG") && $build_config_open++;

if ($build_config_open) {
  $BUILD_CONFIG = File::Spec->rel2abs($BUILD_CONFIG);
  parse_config();
}

if (defined $OVERRIDE_VERSION) {
    print "Overriding build_config version with $OVERRIDE_VERSION\n";
    $VERSION_TAG = $OVERRIDE_VERSION;
    $BUILD_AREA = "/tmp/$VERSION_TAG";
    $INSTALL_DIRECTORY = $BUILD_AREA;
}
if ($OVERRIDE_DISABLE_TESTING) {
  $enable_testing = 0;
}

if (not defined $stop_on_failure) {
    $stop_on_failure = !$quiet;
}
my @transport_projects = ('nnti', 'enet');


my $TAG_DB = "";
our %korvo_projects_override;
my %repositories;
my %config_env_string;
foreach (@config_path) {
    my $eval_file = eval('"'.$_.'/korvo_tag_db'.'"'); warn $@ if $@;
    if (($TAG_DB eq "") && (-f "$eval_file")) {
      $TAG_DB=$eval_file;
      last;
    }
}

if ($TAG_DB ne "") {
  if (-w "$TAG_DB") {
    update_file($TAG_DB);
  }
  if (!$quiet) {
      print "Loading version tag database : " . $TAG_DB . "\n";
  }
  my $return;
  unless ($return = do $TAG_DB) {
    warn "couldn't parse $TAG_DB: $@" if $@;
    warn "couldn't do $TAG_DB: $!"    unless defined $return;
    warn "couldn't run $TAG_DB"       unless $return;
  }
} else {
  print "No tag database found - all packages build from HEAD\n";
}
do "$TAG_DB";
unless (defined $korvo_tag{"$VERSION_TAG"}) { die "Couldn't find version \"$VERSION_TAG\" in korvo_tag_db\n";}

my $SUMMARY = ">$RESULTS_FILES_DIR/build_results$DOT_ARCH";
open SUMMARY, $SUMMARY;
select(SUMMARY);
$| = 1;
select(STDOUT);

if (!$quiet) {
  dump_config();
}

my %config_args = ();
my $host = `hostname`;
chop ($host);
$host =~ s/^\s*//g;
$host =~ s/\s*$//g;
my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isds) 
		    = localtime(time);
$year += 1900;
my $now_string = "$mon/$mday/$year $hour:$min:$sec";
verbose_output ("building on host ", $host, " at ", $now_string,
		"\n\n");

my $CC = $ENV{'CC'};
if (! $CC) { $CC = "cc"; }
my $ccv = `$CC -v 2>&1`;

if (defined $korvo_projects_override{"$VERSION_TAG"}) {
  @projects = split(/\s+/, $korvo_projects_override{"$VERSION_TAG"});
}


if ( ! -d "$BUILD_AREA" ) {
    verbose_output("    Making directory \"$BUILD_AREA\"\n");
    mkdir ("$BUILD_AREA", 0755);
}

my $failed_projects = "";

while(my $project = shift(@projects)) {
    my $repository = $repositories{$project};
    my $result;
    verbose_output("    cd'ing to directory \"$BUILD_AREA\"\n");
    chdir "$BUILD_AREA" || die ("Couldn't chdir to $BUILD_AREA");
    my $PWD="$BUILD_AREA";
    if ( ! -d $project ) {
      verbose_output("    Making directory \"$project\"\n");
      mkdir ($project, 0755);
    }
    verbose_output("    cd'ing to directory \"$project\"\n");
    chdir $project;
    $PWD="$PWD/$project";
    my $src_dir = "$PWD/source";
    my $build_dir;
    if ( $ARCH ne "" ) {
	$build_dir = "$PWD/$ARCH";
    } else {
	$build_dir = "$PWD/build";
    }
    if (! defined($spec{$repository})) {
	print STDERR "Unknown repository specification \"$repository\" for project $project.\n";
	next;
    }

    my $build = 1;
    normal_output("Building project $project\n\twith srcdir=$src_dir and builddir=$build_dir\n");
    sleep 3;
    mkdir $build_dir;
    verbose_output("Removing $build_dir/*\n");
    system("rm -fr $build_dir/*");
    my $repo_spec = '"'.$spec{$repository}.'"';
    my $eval_repo_spec = eval($repo_spec); warn $@ if $@;
    my $rev_arg = "";
    if ("$tool{$repository}" eq "svn") {
      if ("$eval_repo_spec" =~ /^http:\/\/svn.research.cc.gatech.edu/) {
	$rev_arg = "--non-interactive --no-auth-cache --username anon --password anon $rev_arg";
      }
      if ($korvo_tag{"$VERSION_TAG"} =~ /$project:(\w*)/) {
	$rev_arg = "-r $1 $rev_arg";
      }
      my $command = "svn co -q $rev_arg $eval_repo_spec $src_dir";
      normal_output("    ==> $command \n");
      system($command);
      system("cd  $src_dir; svn update $rev_arg 1> /dev/null 2>&1");
    } elsif ("$tool{$repository}" eq "git") {
      if ($korvo_tag{"$VERSION_TAG"} =~ /$project:(\w*)/) {
	$rev_arg = "$1";
	if (lc $rev_arg eq "head") { $rev_arg = "master"; }
      } else {
	$rev_arg = "master";
      }
      if (-d "$src_dir/.git") {
	my $command = "cd $src_dir ; git pull 1> /dev/null 2>&1";
	normal_output("    ==> $command \n");
	system($command);
	if (${?} != 0) {
	   normal_output("    PULL FAILED! ${?}\n");
	   system("rm -fr $src_dir");
	   my $command = "git clone $eval_repo_spec $src_dir";
	   normal_output("    ==> $command \n");
	   system($command);
	   $command = "cd $src_dir ; git pull 1> /dev/null 2>&1";
	   normal_output("    ==> $command \n");
	   system($command);
	}
      } else {
	my $command = "git clone $eval_repo_spec $src_dir";
	normal_output("    ==> $command \n");
	system($command);
	$command = "cd $src_dir ; git pull 1> /dev/null 2>&1";
	normal_output("    ==> $command \n");
	system($command);
      }
      my $command = "cd $src_dir ; git checkout $rev_arg 1> /dev/null 2>&1";
      normal_output("    ==> $command \n");
      system($command);
    } else {
      printf("Unknown tool in build \"$tool{$repository}\"\n");
      exit;
      }
    chdir $build_dir;
    unlink ('config.cache');
    unlink ('config.h');
    unlink ('CMakeCache.txt');
    my $results = "$RESULTS_FILES_DIR/$project/current_install$DOT_ARCH";

    if (! -d "$RESULTS_FILES_DIR/$project") {
	verbose_output("doing mkdir on ".$RESULTS_FILES_DIR . "/".$project."\n");
	mkdir("$RESULTS_FILES_DIR/$project",0777);
    }
    open(RESULTS, ">$results") || die "failed to open $results\n";
    print RESULTS "\nBuilding project $project on $hostname, arch = $ARCH\n\n";
    close(RESULTS);
    my %STORE_ENV = %ENV;		# save environment

    if (defined($config_env_string{$repository})) {
        foreach my $var (split("&", $config_env_string{$repository})) {
            my ($name,$value) = split("=",$var);
	    $ENV{$name} = $value;
	}
    }

    my $tmp = eval('"'.$INSTALL_DIRECTORY.'"');
    my $THIS_INSTALL_DIRECTORY = $tmp;
    if ( ! -d "$THIS_INSTALL_DIRECTORY" ) {
	verbose_output("    Making directory \"$THIS_INSTALL_DIRECTORY\"\n");
	mkdir ("$THIS_INSTALL_DIRECTORY", 0755);
    }
    chomp($tmp=`cd "$THIS_INSTALL_DIRECTORY"; pwd`);
    $THIS_INSTALL_DIRECTORY=$tmp;
    my $config_command;
    if ( -r "$src_dir/CMakeLists.txt" ) {
        my $args = '"';
	if (defined($cmake_args{$repository})) {
	    $args.= "$cmake_args{$repository}";
	}
	if ($enable_testing && ("$ARCH" ne "")) {
	  $args.=" -DBUILDNAME=$project-$ARCH";
	}
	if ($enable_testing == 0) {
	  $args.=" -DENABLE_TESTING=0"
	}
	if ($enable_debug_build > 0) {
	  $args.=" -DCMAKE_BUILD_TYPE=Debug"
	}
	if ($THIS_INSTALL_DIRECTORY) {
	  $args.=" -DCMAKE_INSTALL_PREFIX=$THIS_INSTALL_DIRECTORY";
	}
	if ($EVPATH_TEST_INSTALL_DIR && ($project eq "evpath")) {
	  $args.=" -DTEST_INSTALL_DIRECTORY=$EVPATH_TEST_INSTALL_DIR";
	}
	$args.='"';
	my $eval_args = eval($args); warn $@ if $@;
	normal_output("    ==> cmake $eval_args $src_dir\n");
	$config_command = "cmake $eval_args $src_dir 1>>$results 2>&1";
    } else {
        my $args = '"';
	if (defined($config_args{$repository})) {
	    $args.= ".$config_args{$repository}";
	}
	if ($enable_debug_build > 0) {
	  $args.= " CFLAGS='-g -O0' CPPFLAGS='-g -O0' "
	}
	my $dir;
	if ($THIS_INSTALL_DIRECTORY) {
	    $args.= "--prefix=$THIS_INSTALL_DIRECTORY";
	}
	$args.='"';
	my $eval_args = eval($args); warn $@ if $@;
	if (($dir) = ($eval_args =~ /.*-bindir=(\S+)\b.*/)) {
	  if (! -d $dir) {
	    verbose_output("doing bin mkdir on $dir\n");
	    verbose_output("in was $eval_args\n");
	    mkdir($dir,0777);
	  }
	}
	if (($dir) = ($eval_args =~ /.*-libdir=(\S+)\b.*/)) {
	  if (! -d $dir) {
	    verbose_output("doing lib mkdir on $dir\n");
	    verbose_output("in was $eval_args\n");
	    mkdir($dir,0777);
	  }
	}
	if (($dir) = ($eval_args =~ /.*-includedir=(\S+)\b.*/)) {
	  if (! -d $dir) {
	    verbose_output("doing include mkdir on $dir\n");
	    verbose_output("in was $eval_args\n");
	    mkdir($dir,0777);
	  }
	}
	normal_output("    ==> $src_dir/configure $eval_args\n");
	$config_command = "$src_dir/configure $eval_args 1>>$results 2>&1";
    }
    verbose_output("Doing $config_command\n");
    system($config_command);
    system("make clean 1> /dev/null 2>&1");
    if ( -r "$src_dir/CMakeLists.txt") {
	open CMFILE, "$src_dir/CMakeLists.txt" or die $!;
	my @cmfile = <CMFILE>;
	if ( grep( /^ENABLE_TESTING()/,@cmfile ) && $enable_testing ) {

	    # do a make test
	    system("make clean 1>>/dev/null 2>&1");
	    normal_output("    ==> make\n");
	    system("make 1>>$results 2>&1");
	    $result = 0;
	    normal_output("    ==> make test\n");
	    $result = system("make test 2>&1 | sed 's/[0-9.]* sec//g' 1>>$results");
	    if (($result/256) == 0) {
		normal_output("    ==> make install\n");
		$result = system("make install 1>>$results 2>&1");
	    } else {
		system("echo \"TESTING FAILED, NO INSTALL, result from make test ${?}\" 1>>$results");
	    }
        } else {
	    verbose_output("ENABLE_TESTING NOT FOUND or testing disabled\n");
	    normal_output("    ==> make all install\n");
	    $result = system("make all install 1>>$results 2>&1");
        }
	close CMFILE;
    } elsif ( -r "Makefile.am") {
	# do a make check
	system("make depend 1> /dev/null 2>&1 ");
	if ($enable_testing) {
	    normal_output("    ==> make check install\n");
	    $result = system("make check install 1>>$results 2>&1");
	} else {
	    normal_output("    ==> make install\n");
	    $result = system("make install 1>>$results 2>&1");
	}	    
    } else {
      normal_output("    ==> make install\n");
	$result = system("make install 1>>$results 2>&1");
    }
    if (($result / 256) != 0) {
        if ($stop_on_failure) {
	}
	possible_exit_on_failure ($project);
	$failed_projects .= " $project";
    }
    if ( ! -r ".no_clean") {
	system("make clean 1> /dev/null 2>&1");
    }
    %ENV = %STORE_ENV;		# restore environment
}

$_ = $HOME;
my $evpath_rel_rev = `grep "EVPath Version" ${BUILD_AREA}/evpath/source/version.c | sed 's/.* Version //;s/ .*//'`;
chomp($evpath_rel_rev);
&_generate_build_xml($VERSION_TAG, $evpath_rel_rev, $failed_projects, $ARCH, $BUILD_CONFIG);

if ($failed_projects ne "") {
    normal_output("\n\nThese projects failed to install : $failed_projects\n");
    normal_output("   * More detailed build output is available in $RESULTS_FILES_DIR/<project> \n\n");
    normal_output("These failures may or may not be important depending upon what packages you need.\n");
    normal_output("If \"evpath\" is not listed as one of the projects that failed to install, then \n");
    normal_output("the evpath library has been installed and is available in the specified install directory\n\n");
    if (index($failed_projects, "nnti") != -1) {
      normal_output("- nnti failure possible cause: NNTI supports EVPath RDMA transport and will not \n");
      normal_output("  build unless it finds an RDMA interface, but is not needed unless you're doing RDMA work.\n");
    }
    if (index($failed_projects, "soapstone") != -1) {
      normal_output("- soapstone failure possible cause: Soapstone requires gsoap2 and will fail if it is not found\n");
      normal_output("  This is a supplementary project and not necessary to use EVPath\n");
    }
    if (index($failed_projects, "pds") != -1) {
      normal_output("- pds failure possible cause: The PDS package requires libxml2 and will fail if it is not found\n");
      normal_output("  This is a supplementary project and not necessary to use EVPath\n");
    }
    if (index($failed_projects, "comm_group") != -1) {
      normal_output("- comm_group : This is a supplementary project and not necessary to use EVPath\n");
    }
    if (index($failed_projects, "cmrpc") != -1) {
      normal_output("- cmrpc : This is a supplementary project and not necessary to use EVPath\n");
    }
    if (index($failed_projects, "gs") != -1) {
      normal_output("- gs : This is a supplementary project and not necessary to use EVPath\n");
    }
    if (index($failed_projects, "lgs") != -1) {
      normal_output("- lgs : This is a supplementary project and not necessary to use EVPath\n");
    }
}

sub _generate_build_xml {
  my ($release_name, $release_rev, $fail_list, $platform, $build_config_file) = @_;

  if ("$platform" eq "") { return; }

  open BUILD_RESULTS_FILE, ">/tmp/build_results_$$.xml" or die "failed to open build_results XML output";

  print BUILD_RESULTS_FILE "<?xml version='1.0'?>\n<build_result>\n";
  print BUILD_RESULTS_FILE "<releasename>$release_name</releasename>\n";
  print BUILD_RESULTS_FILE "<releasetag>$release_rev</releasetag>\n";
  print BUILD_RESULTS_FILE "<platform>$platform</platform>\n";
  print BUILD_RESULTS_FILE "<hostname>$hostname</hostname>\n";
  print BUILD_RESULTS_FILE "<user>$USER</user>\n";
  my $uname = `uname -a`;
  print BUILD_RESULTS_FILE "<uname>$uname</uname>\n";
  my $CC = $ENV{'CC'};
  if (! $CC) { $CC = "cc"; }
  my $ccv = `$CC -v 2>&1`;
  $ccv =~ s/&/&amp;/sg;
  $ccv =~ s/</&lt;/sg;
  $ccv =~ s/>/&gt;/sg;
  $ccv =~ s/"/&quot;/sg;    
  print BUILD_RESULTS_FILE "<ccv>$ccv</ccv>\n";
  
  my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) =
                                                localtime(time);
  $year += 1900;
  $mon += 1;
  print BUILD_RESULTS_FILE "<date>$mon/$mday/$year</date>\n";
  if (index($failed_projects, 'evpath') == -1) {
    print BUILD_RESULTS_FILE "<buildstatus>1</buildstatus>\n";
  } else {
    print BUILD_RESULTS_FILE "<buildstatus>0</buildstatus>\n";
  }
  print BUILD_RESULTS_FILE "<build_config>\n";
  my $conf;
  my $include_build_config = 0;
  foreach $conf (keys %cmake_args) {
    if (defined $cmake_args{$conf} && ($cmake_args{$conf} !~ /^\s*$/)) {
      $include_build_config = 1;
    }
  }
  foreach $conf (keys %config_args) {
    if (defined $config_args{$conf} && ($config_args{$conf} !~ /^\s*$/)) {
      $include_build_config = 1;
    }
  }
  if ($include_build_config) {
    open my $fh, "<$BUILD_CONFIG" or die;
    $/ = undef;
    my $build_config = <$fh>;
    close $fh;
    $build_config =~ s/&/&amp;/sg;
    $build_config =~ s/</&lt;/sg;
    $build_config =~ s/>/&gt;/sg;
    $build_config =~ s/"/&quot;/sg;    
    print BUILD_RESULTS_FILE "$build_config";
  }
  print BUILD_RESULTS_FILE "</build_config>\n";
  print BUILD_RESULTS_FILE "<module_list>\n";

  my $fh;
  if (&Which("module")) {
    open $fh, "module list 2>&1 |" or die;
  } elsif (&Which("modulecmd")) {
    open $fh, "modulecmd tcsh list 2>&1 |" or die;
  } 

  if ($fh) {
    $/ = undef;
    my $module_list = <$fh>;
    close $fh;
    $module_list =~ s/&/&amp;/sg;
    $module_list =~ s/</&lt;/sg;
    $module_list =~ s/>/&gt;/sg;
    $module_list =~ s/"/&quot;/sg;    
    print BUILD_RESULTS_FILE $module_list;
  }
  print BUILD_RESULTS_FILE "</module_list>\n";
  print BUILD_RESULTS_FILE "</build_result>\n";
  close BUILD_RESULTS_FILE;
  system("wget -q --post-file=/tmp/build_results_$$.xml  -O - http://evpath.net/submit.php");
  unlink("/tmp/build_results_$$.xml");
  if (defined $OVERRIDE_VERSION) {
      system("rm -fr /tmp/$VERSION_TAG");
  }
}

sub parse_config {
  my $parsing;
  @projects = ();
  $RESULTS_FILES_DIR="/tmp/build_results_$USER";
  $BUILD_AREA="$HOME/korvo_build_area";
  $VERSION_TAG="stable";
  while(<CONFIG>) {
    if (/^%BUILDLIST/) {	$parsing = "list"; next; }
    elsif (/^%REPOSITORIES/) {	$parsing = "repos"; next; }
    elsif (/^%CONFIGURE/) {	$parsing = "args"; next; }
    elsif (/^[ \t]*%/) { next;}
    elsif (/DISABLE_TESTING/) { $enable_testing = 0; next; }
    elsif (/ENABLE_DEBUG_BUILD/) { $enable_debug_build++; next; }
    elsif (/RESULTS_FILES_DIR/) {
	$_ =~ m{.*=\s*(\S+)};
	$RESULTS_FILES_DIR = $1;
    }
    elsif (/INSTALL_DIRECTORY/) {
	$_ =~ m{.*=\s*(\S+)};
        $INSTALL_DIRECTORY = $1;
    }
    elsif (/BUILD_AREA/) {
	$_ =~ m{.*=\s*(\S+)};
	$BUILD_AREA = $1;
    }
    elsif (/EVPATH_TEST_INSTALL_DIR/) {
	$_ =~ m{.*=\s*(\S+)};
	$EVPATH_TEST_INSTALL_DIR = $1;
    }
    elsif (/VERSION_TAG/) {
	$_ =~ m{.*=\s*(\S+)};
	$VERSION_TAG = $1;
    }
    elsif (/^%/) {next;}
    elsif (/^#/) {next;}
    elsif (/^[ 	]*$/) {next;}
    else {
      if ($parsing eq "list") {
	my ($project,$repository,$notify_users) = split(/[ \t\n]+/,$_,3);
	push(@projects, $project);
	$repositories{$project} = $repository;
      } elsif ($parsing eq "repos") {
	$_ =~ m/\s*(\S+)\s+(\S+)\s+(\S+)/;	
	my ($repo, $tool, $spec);
	$repo = $1; $tool = $2; $spec = $3;
#	($repo,$tool,$spec) = split(/[ \t]+/,$_,3);
	$tool{$repo} = $tool;
	$spec{$repo} = $spec;
      } elsif ($parsing eq "args") {
	chomp();
	my ($repo,$conf, $args) = split(/[ \t]+/,$_,3);
	if (defined($conf)) {
	  if ($conf eq "cmake") {
	    $cmake_args{$repo} = $args;
	  } elsif ($conf eq "configure") {
	    $config_args{$repo} = $args;
	  } else {
	    printf("Unknown configure type \"$conf\" in build_config.");
	  }
	}
      }
    }
  }
  my $eval_build_area = eval('"'.$BUILD_AREA.'"'); warn $@ if $@;
  $BUILD_AREA=$eval_build_area;
  if ( ! -d "$BUILD_AREA" ) {
    print("    Making directory \"$BUILD_AREA\"\n");
    mkdir ("$BUILD_AREA", 0755);
  }
  my $tmp;
  chomp($tmp=`cd "$BUILD_AREA"; pwd`);
  $BUILD_AREA=$tmp;
  if ( ! -d "$RESULTS_FILES_DIR" ) {
    print("    Making directory \"$RESULTS_FILES_DIR\"\n");
    mkdir ("$RESULTS_FILES_DIR", 0755);
  }
  chomp($tmp=`cd "$RESULTS_FILES_DIR"; pwd`);
  $RESULTS_FILES_DIR=$tmp;
}

sub dump_config {
  if ("$ARCH" ne "") {
    print("Build configured by $BUILD_CONFIG for architecture $ARCH on host $hostname\n\t\tInstalling to $INSTALL_DIRECTORY\n");
  } else {
    print("Build configured by $BUILD_CONFIG on host $hostname\n\t\tInstalling to $INSTALL_DIRECTORY\n");
  }
  print("Building version tagged with $VERSION_TAG\n");
  print("Builds are to be performed under directory : $BUILD_AREA\n");
  print("Result files are to be placed in directory : $RESULTS_FILES_DIR\n");
  if ($enable_testing) {
    print("    Package tests will be run prior to installation.\n");
  } else {
    print("    Package tests will *NOT* be run prior to installation.\n");
  }
  print("\n\n");
}
sub normal_output {
    if (!($quiet != 0)) {
	foreach my $foo (@_) {
	    print $foo;
	}
    }
    foreach my $foo (@_) {
	print SUMMARY $foo;
    }
}

sub verbose_output {
    if ($verbose != 0) {
	foreach my $foo (@_) {
	    print $foo;
	}
    }
    foreach my $foo (@_) {
	print SUMMARY $foo;
    }
}
sub check_needed_commands {
  my $make_found = `which make`;
  my $cmake_found = `which cmake`;
  my $svn_found = `which svn`;
  my $git_found = `which git`;
  my $flex_found = `which flex`;
  my $lex_found = `which lex`;
  my $yacc_found = `which yacc`;
  my $bison_found = `which bison`;
  my $exit = 0;
  if ("$make_found" eq "") {
    printf("Didn't find 'make', required for build\n"); $exit++;
  }
  if ("$cmake_found" eq "") {
    printf("Didn't find 'cmake', required for build\n"); $exit++;
  } else {
    my ($substr) = `cmake --version` =~ /(?<=cmake version )([^.]+)/g;
    if ("$substr" < 3) {
      printf("EVPath build requires CMake 3.0 or higher\n"); $exit++;
    }
  }
  if ("$svn_found" eq "") {
    printf("Didn't find 'svn', required for build\n"); $exit++;
  }
  if ("$git_found" eq "") {
    printf("Didn't find 'git', required for build\n"); $exit++;
  }
  if (("$flex_found" eq "") and ("$lex_found" eq "")){
    printf("Didn't find either of 'flex' or 'lex', these are required for FFS, which is required for EVPath\n"); $exit++;
  }
  if (("$yacc_found" eq "") and ("$bison_found" eq "")){
    printf("Didn't find either of 'yacc' or 'bison', these are required for FFS, which is required for EVPath\n"); $exit++;
  }
  ($exit == 0) || die("Some required components missing, korvo_build aborted");
}



sub update_file {
    my ($filename) = @_;
    my $base = basename $filename;
    my $dir = dirname $filename;
    my ($ua, $response);
    state $has_lwp = -1;

    if (-d $dir . "/.svn") {
      # if under svn, do an svn update 
      system('cd "$dir" ; svn -q update');
      return;
    }
    if ($has_lwp == -1) {
      $has_lwp = eval
	{
	  require LWP::UserAgent;
	  require LWP::Protocol::https;
	  LWP::UserAgent->new();
	  1;
	};
    }
    $has_lwp = 0 unless defined($has_lwp);
    if($has_lwp) {
      # LWP::UserAgent loaded and imported successfully
      my $ua = LWP::UserAgent->new();
      $ua->env_proxy();

      $response = $ua->get("https://GTkorvo.github.io/$base");
     
      if ($response->is_success) {
	open(FILE, ">/tmp/$base");
	print FILE $response->decoded_content;
	close FILE;
      } else {
        print "Error updating $base: " . $response->status_line . "\n";
	return;
      }
    } else {
      my $ret = system("cd /tmp ; rm -f $base ; wget -q https://GTkorvo.github.io/$base");
      my $exit_value = $ret >> 8;
      if ($exit_value != 0) {
	die("This script requires either the perl module LWP::UserAgent, or the command 'wget' to be installed\n\tThe former was not found and the latter failed.");
      }
    }

  if (system("cmp -s $filename /tmp/$base") != 0) {
    system("mv /tmp/$base $filename");
    print "Installed fresh $filename\n";
  } else {
    unlink("/tmp/$base");
    print "No need to update $filename\n";
  }
}

sub possible_exit_on_failure {
    my $failed_project = shift;

    my $count=map {m/^$failed_project$/i} @transport_projects;
    if ($count) {
        print "\n				BUILD FAILURE of OPTIONAL PROJECT			\n";
	if ("$failed_project" eq "nnti") {
	    print "\tProject nnti has failed to configure/build/install.  \n";
	    print "\tnnti is an RDMA wrapper library used to provide a high performance network \n";
	    print "\ttransport in EVPATH on machines where RDMA is available.  If you are\n";
	    print "\tbuilding on a machine without an RDMA interface, this is an expected failure. \n";
	    print "\tEVPath can still be built, but will operate without RDMA capabilities.  \n";
	    print "\tTherefore this build script will continue to execute.\n";
	    print "\tHowever, if you think you *should* be building for RDMA, you can examine the file:\n";
	    print "\t$RESULTS_FILES_DIR/$failed_project/current_install$DOT_ARCH for clues as to what went wrong.\n\n";
         } else {
	    print "\tProject $failed_project has failed to configure/build/install.  However, \n";
	    print "\t$failed_project is not a critical project for EVPath, so this build script\n";
	    print "\twill continue to execute.\n";
	    print "\tIf you are curious about the failure, you can examine the file:\n";
	    print "\t$RESULTS_FILES_DIR/$failed_project/current_install$DOT_ARCH\n";
	    print "\tfor clues as to what went wrong.\n\n";
	 }
    } else {
	print "\t				BUILD FAILURE of CRITICAL PROJECT			\n";
	print "\tProject $failed_project has failed to configure/build/install.  \n";
	print "\tThis project is necessary for EVPath, so the build is exiting now\n";
	print "\tOutput from the failed build has been left in the file:\n";
	print "\t$RESULTS_FILES_DIR/$failed_project/current_install$DOT_ARCH\n";
	print "\tPlease examine that file for clues.\n";
	die ("Critical project build failure");
    }
}

sub Which {

# Get the passed value
  my $program = shift;

# Return if nothing is provided
  return if (not defined($program));

# Load the path
  my $path = $ENV{'PATH'};

# Let's replace all \ by /
  $path =~ s/\\/\//g;

# Substitute all /; by ; as there could be some trailing / in the path
  $path =~ s/\/;/;/g;

# Now make an array
  my @path = split(/:/,$path);

# Loop and find if the file is in one of the paths
  foreach (@path) {

  # Concatenate the file
    my $file = $_ . '/' . $program;

  # Return the path if it was found
    return $file if ((-e $file) && (-f $file));
  }
}
