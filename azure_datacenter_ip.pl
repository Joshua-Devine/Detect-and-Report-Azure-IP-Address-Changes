#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long;
use LWP::UserAgent;
use LWP::Protocol::https;
use LWP::Simple;
use Date::EzDate;
use File::Copy;

#Globals
my $url_azure='https://azservicetags.azurewebsites.net/';
my $azure_opt='./data/azure_ip.opt';
my $azure_baseline_dat='./data/azure_ip.bas';
my $azure_baseline_folder='./baselines/';
my $logfile='./logs/azure_ip.log';
my $report_folder='./report/';
my $github_loc='https://github.com/Joshua-Devine/Detect-and-Report-Azure-IP-Address-Changes';

my $raw_json; #contains the content of ServiceTags_*.json from $url_azure, depending on parent_location chosen

my %parent_loc_def=(               #which JSON to download, values contain regex to grab href from $url_azure to obtain the respective URL for the file to d/l
   "public"=>'a href="(https:\/\/.*?ServiceTags_Public.*?\.json)',
   "government"=>'a href="(https:\/\/.*?ServiceTags_AzureGovernment.*?\.json)',
   "germany"=>'a href="(https:\/\/.*?ServiceTags_AzureGermany.*?\.json)',
   "china"=>'a href="(https:\/\/.*?ServiceTags_China.*?\.json)'); 

my %data;
#$data{$parent}{$region}{systemservice}[0]="Change number for this service"
#$data{$parent}{$region}{systemservice}[1]="Name", which is almost identical to "ID"
#$data{$parent}{$region}{systemservice}[2]="list of IPv4 addresses"
#$data{$parent}{$region}{systemservice}[3]="list of IPv6 addresses"
#$data{$parent}{$region}{systemservice}[4]=1, if selected via CLI or Import

my %baseline;
#$baseline{$parent}{$region}{systemservice}[0]="Change number for this service"
#$baseline{$parent}{$region}{systemservice}[1]="Name", which is almost identical to "ID"
#$baseline{$parent}{$region}{systemservice}[2]="list of IPv4 addresses"
#$baseline{$parent}{$region}{systemservice}[3]="list of IPv6 addresses"
#$baseline{$parent}{$region}{systemservice}[4]=1, if selected via CLI or Import

my %delta_ip;
#$delta_ip{$parent}{$region}{$systemservice}[0]="New IPv4s"
#$delta_ip{$parent}{$region}{$systemservice}[1]="New IPv6s"
#$delta_ip{$parent}{$region}{$systemservice}[2]="Remove IPv4s"
#$delta_ip{$parent}{$region}{$systemservice}[3]="Remove IPv6s"

my %service_delta;
#$service_delta{$parent}{$region}{$systemservice}[0]=baseline services not found
#$service_delta{$parent}{$region}{$systemservice}[1]=current services not found
#$service_delta{$parent}{$region}{$systemservice}[2]=services that existed in the baseline, but are no longer found in the current

my %delta_sel;
#$delta_sel{'new'}{'region'}=$region
#$delta_sel{'new'}{'systemservice'}=$systemservice
#$delta_sel{'old'}{'region'}=$region
#$delta_sel{'old'}{'systemservice'}=$systemservice

my $preamble; #output string, includes: change/no-change, contains commandline arguments used with --delta, date of baseline, date of runtime, delta of the dates, baseline name, option name, options selected

my %selected; #store CLI or CSV import selections for parent, region, and systemservice for current JSON
#selected{$parent}{$region}{$systemservice}=(0,1,2) 0="not selected" 1="selected but not found" 2="selected and found"

my %selected_base; #store CLI or CSV import selections for parent, region, and systemservice for stored BASELINE

my %compress; #storing uniq IP addresses
#compress{"ipv4"}{ipv4 addresses}=1
#compress{"ipv6"}{ipv6 addresses}=1

my $print_out; 

#CLI Parameters
my $show=0; #flag to show selected parent, region, and services, defaults to 'public' parent location, all regions per parent, and all services available per region
my $ipv4=0; #flag to print respective IPv4 addresses
my $ipv6=0; #flag to print respective IPv6 addresses
my $help=0; #flag to display usage
my $csv_out=0; #flag to output in csv format
my $display=0; #flag to display the IPs based on the parent, region, service, IPv4, IPv6 options selected, or only display the delta if --delta is used
my $compress=0; #flag to compress IPv4 and/or IPv6 addresses as it pertains to the scope
my $delta; #contains stored baseline file in order to display delta's on the stored options available in the baseline file
my @parent; #list of available parent locations to display, stored in parent_location (parent defaults to "public" if not set)
my @region; #list of regions to display per the parent(s) selected 
my @service; #list of services to display per the region(s) selected 
my $import_csv; #filename provided by CLI options to be read in for a more granular selection
my $c_baseline; #string provided by CLI to create a new baseline (named by string) to be saved and later compared against
my $set_opt; #name to save your options in $azure_opt
my $use_opt; #name to use your options in $azure_opt
my $use_baseline; #string provided by CLI to use an existing baseline

my %opts=(
   show=>\$show,
   display=>\$display,
   ipv4=>\$ipv4,
   ipv6=>\$ipv6,
   help=>\$help,
   csv=>\$csv_out,
   compress=>\$compress,
   parent=>\@parent, #defaults to public
   region=>\@region, #defaults to all regions
   service=>\@service, #defaults to all services
   create_baseline=>\$c_baseline,
   use_baseline=>\$use_baseline,
   import_csv=>\$import_csv,
   use_opt=>\$use_opt,
   set_opt=>\$set_opt,
   delta=>\$delta,
);

GetOptions (
   \%opts,
   "show",
   "help",
   "display",
   "ipv4",
   "ipv6",
   "csv",
   "compress",
   "parent|parents=s{,}",
   "delta",
   "import_csv=s",
   "use_opt=s",
   "set_opt=s",
   "region|regions=s{,}",
   "service|services=s{,}",
   "create_baseline=s",
   "use_baseline=s",
), or logger("Invalid Selection",1);

#MAIN
log_cli_options();
process_options();

#########################################################
sub log_cli_options {
   my $output="Command line execution: $0 ";
   $output.=sprintf ("--show "), if ($show);
   $output.=sprintf ("--display "), if ($display);
   $output.=sprintf ("--ipv4 "), if ($ipv4);
   $output.=sprintf ("--ipv6 "), if ($ipv6);
   $output.=sprintf ("--csv "), if ($csv_out);
   $output.=sprintf ("--compress "), if ($compress);
   $output.=sprintf ("--delta "), if ($delta);
   if (@parent) {
      $output.=sprintf ("--parent ");
      map{$output.=sprintf ("\"$_\" ")} (@parent);
   }
   if (@region) {
      $output.=sprintf ("--region ");
      map{$output.=sprintf ("\"$_\" ")} (@region);
   }
   if (@service) {
      $output.=sprintf ("--service ");
      map{$output.=sprintf ("\"$_\" ")} (@service);
   }
   $output.=sprintf ("--create_baseline \"$c_baseline\" "), if ($c_baseline);
   $output.=sprintf ("--use_baseline \"$use_baseline\" "), if ($use_baseline);
   $output.=sprintf ("--import_csv \"$import_csv\" "), if ($import_csv);
   $output.=sprintf ("--use_opt \"$use_opt\" "), if ($use_opt);
   logger("################################ New Command ################################",0);
   logger("$output",0);
} #end sub log_cli_options

#########################################################
sub logger {

   my $string=shift;
   my $print_error=shift; #0=log with no errors or warnings, 1=exit with error 1, 2=no exit but log warning
   my $count=shift;
   my $current_date=Date::EzDate->new();

   if ($print_error == 1) {
      $string="#ERROR: $string";
      printf STDERR "$string\n";
   } elsif ($print_error == 2) {
      $string="#WARNING: $string";
      printf STDERR "$string\n";
   }

   if (open (LOG, '>>', "$logfile")) {
      printf LOG ("$current_date: \"$string\"\n");
      close LOG;
      exit 1, if ($print_error == 1);
   } else {
      print STDERR "#ERROR: FAILED TO OPEN $logfile\n";
      check_dir_file($logfile);
      ++$count;
      die "Cannot open $logfile for writing!: \"$!\"", if ($count > 2);
      logger("$string", $print_error, $count);
   }

} #end sub logger

#########################################################
sub process_options {

   $use_opt=lc($use_opt), if (defined($use_opt));
   $set_opt=lc($set_opt), if (defined($set_opt));
   $c_baseline=lc($c_baseline), if (defined($c_baseline));
   $use_baseline=lc($use_baseline), if (defined($use_baseline));

   if ($help) {
      usage();
      exit 0;

   } elsif ($show && ($ipv4 || $ipv6 || $delta || $c_baseline || $compress || $display || $import_csv)) {
      logger("--show cannot be used with options such as: --ipv4 --ipv6 --delta --create_baseline --compress --display --import_csv",1);

   } elsif ($delta && $use_baseline) {
      logger("--delta cannot be used with options such as: --show --import_csv",1), if ($show || $import_csv);

      my $c_date=Date::EzDate->new();
      $c_date->{'default'}='{year}.{month number base 1}.{day of month}-{epoch second}';
      my %baseline_contents; #%baseline_contents{parent}=filename of baseline file

      $ipv4=1, unless ($ipv4 || $ipv6); #display ipv4 if neither option is set

      if ($use_opt) {
	 logger("Cannot use --parent --region --service with --use_opt and --delta",1), if (@parent or @region or @service);
	 read_options($azure_opt, $use_opt, \%selected); #read options from stored file and populate parent, region, service in %selected
	 read_options($azure_opt, $use_opt, \%selected_base); #read options from stored file and populate parent, region, service in %selected_base
      } else {
	 pre_process_cli_selections();
      }

      read_baseline($use_baseline, \%baseline_contents, 1); 

      foreach my $p (@parent) {
	 #populate %baseline with saved baseline data
	 my $content;
	 open $content, "< ${azure_baseline_folder}$baseline_contents{$p}", or logger("Cannot open baseline file:\"${azure_baseline_folder}$baseline_contents{$p}\" for reading!: \"$!\"",1);
	 $raw_json=do { local $/; <$content> };
	 close $content;
	 parse_download($raw_json, $p, \%baseline);

	 #populate %data with current state
	 $raw_json=retrieve_ip($parent_loc_def{$p});
	 parse_download($raw_json, $p, \%data);
      }

      if ($use_opt) {
	 build_selection("options", \%baseline, \%selected_base, "baseline"); #use preprocess to populate %selected_base
	 build_selection("options", \%data, \%selected, "current"); #use preprocess to populate %selected
      } else {
	 build_selection("cli", \%baseline, \%selected_base, "baseline"); #use preprocess to populate %selected_base
	 build_selection("cli", \%data, \%selected, "current"); #use preprocess to populate %selected
      }

      process_delta();
      $print_out=display_delta();
      print "$print_out";
      logger("Writing results of --delta to ${report_folder}$c_date",0);
      check_dir_file("${report_folder}");
      open R, "> ${report_folder}$c_date" or logger("Cannot open ${report_folder}$c_date for writing!: \"$!\"",2);
      print R $print_out;
      close R;

      if ($c_baseline) {
	 logger ("Overwriting existing baseline with new data",2);
	 my $baseline_date=Date::EzDate->new();
	 my @baseline_contents;
	 $baseline_date->{'default'}='{year}.{month number base 1}.{day of month}-{epoch second}';

	 %data=(); #Clear data just in case

	 foreach my $p (@parent) {
	    $raw_json=retrieve_ip($parent_loc_def{$p}); 
	    parse_download($raw_json, $p, \%data);
	    push (@baseline_contents, write_baseline_files($raw_json, $azure_baseline_folder, $baseline_date, $p));
	 }

	 $c_baseline=write_baseline_dat($azure_baseline_dat, $c_baseline, \@baseline_contents, "yes");
      }

   } elsif ($use_baseline) {
      logger ("--create_baseline cannot be used with --use_baseline",1), if ($c_baseline);
      my %baseline_contents;
      #%baseline_contents{parent}=filename of baseline file

      if ($use_opt) {
	 logger("Cannot use --parent --region --service with --use_opt when using --create_baseline",1), if (@parent or @region or @service);
	 read_options($azure_opt, $use_opt, \%selected); #read options from stored file and populate parent, region, service in %selection
      } else {
	 pre_process_cli_selections();
      }

      read_baseline($use_baseline, \%baseline_contents, 1);

      foreach my $p (@parent) {
	 my $content;
	 open $content, "< ${azure_baseline_folder}$baseline_contents{$p}", or logger("Cannot open baseline file:\"${azure_baseline_folder}$baseline_contents{$p}\" for reading!: \"$!\"",1);
	 $raw_json=do { local $/; <$content> };
	 close $content;
	 parse_download($raw_json, $p, \%data);
      }

      if ($use_opt) {
	 build_selection("options", \%data, \%selected); #use preprocess to populate %selected
      } else {
	 build_selection("cli", \%data, \%selected); #use preprocess to populate %selected
      }
      
      if ($display) {
	 $ipv4=1, unless ($ipv4 || $ipv6); #display ipv4 if neither option is set
	 logger("Cannot use both --csv and --compress with --display",1), if ($compress && $csv_out);
	 $print_out=build_display(\%data);
	 print "$print_out\n";
      }

      if ($show) {
	 print_show(\%data);
      }

   } elsif ($c_baseline) {
      logger("Cannot use --use_baseline with --create_baseline",1), if ($use_baseline);
      my $baseline_date=Date::EzDate->new();
      my @baseline_contents;
      $baseline_date->{'default'}='{year}.{month number base 1}.{day of month}-{epoch second}';

      if ($use_opt) {
	 logger("Cannot use --parent --region --service with --use_opt when using --create_baseline",1), if (@parent or @region or @service);
	 read_options($azure_opt, $use_opt, \%selected); #read options from stored file and build selection
      } else {
	 pre_process_cli_selections();
      }

      foreach my $p (@parent) {
	 $raw_json=retrieve_ip($parent_loc_def{$p}); 
	 parse_download($raw_json, $p, \%data);
	 push (@baseline_contents, write_baseline_files($raw_json, $azure_baseline_folder, $baseline_date, $p));
      }

      $c_baseline=write_baseline_dat($azure_baseline_dat, $c_baseline, \@baseline_contents, "unknown");

      if ($set_opt) {
	 logger("Cannot use --use_opt with --set_opt",1), if ($use_opt);
	 build_selection("cli", \%data, \%selected); #use preprocess to populate %selected
	 write_options($azure_opt, $set_opt);
      }


   } elsif ($display) {
      $ipv4=1, unless ($ipv4 || $ipv6); #display ipv4 if neither option is set

      logger("Cannot use both --csv and --compress with --display",1), if ($compress && $csv_out);

      if ($use_opt) {
	 logger("Cannot use --parent --region --service with --use_opt when using --display",1), if (@parent or @region or @service);

	 read_options($azure_opt, $use_opt, \%selected); #read options from stored file and build selection
	 foreach my $p (@parent) {
	    $raw_json=retrieve_ip($parent_loc_def{$p});
	    parse_download($raw_json, $p, \%data);
	 }
	 build_selection("options", \%data, \%selected); #use preprocess to populate %selected
      } else {
	 pre_process_cli_selections(); 
	 foreach my $p (@parent) {
	    $raw_json=retrieve_ip($parent_loc_def{$p});
	    parse_download($raw_json, $p, \%data);
	 }
	 build_selection("cli", \%data, \%selected); #use preprocess to populate %selected
      }

      $print_out=build_display(\%data);
      print "$print_out\n";

   } elsif (($import_csv && $set_opt) && ((not $ipv4) || (not $ipv6) || (not $use_opt) || (not $compress) || (not @parent)|| (not @region)|| (not @service)|| (not $csv_out))) {
      csv_import($import_csv);
      write_options($azure_opt, $set_opt);

   } elsif ($show) {
      if ($use_opt) {
	 logger("Cannot use --parent --region --service with --use_opt when using --create_baseline",1), if (@parent or @region or @service);
	 read_options($azure_opt, $use_opt, \%selected); #read options from stored file and build selection
      } else {
	 pre_process_cli_selections();
      }

      foreach my $p (@parent) {
	 $raw_json=retrieve_ip($parent_loc_def{$p});
	 parse_download($raw_json, $p, \%data);
      }

      if ($use_opt) {
	 build_selection("options", \%data, \%selected);
      } else {
	 build_selection("cli", \%data, \%selected);
      }

      print_show(\%data);

   } elsif ($set_opt) {
      logger("Cannot use --use_opt with --set_opt",1), if ($use_opt);
      pre_process_cli_selections();
      foreach my $p (@parent) {
	 $raw_json=retrieve_ip($parent_loc_def{$p});
	 parse_download($raw_json, $p, \%data);
      }
      build_selection("cli", \%data, \%selected);
      write_options($azure_opt, $set_opt);
   } else {
      usage();
      exit 1;
   }

} #end sub process_options

#########################################################
sub display_delta {

   my $out="\n"; #store output temporarily and return it to parent
   
   if (($delta_sel{'new'}{'region'}) || ($delta_sel{'new'}{'systemservice'}) ||($delta_sel{'old'}{'region'}) ||($delta_sel{'old'}{'systemservice'})) {
      $out.=sprintf("\nCheck for potential changes to the regions and/or services offered from your selected baseline and the current state.  Review and determine if new selections are required. If they are required, then use those new selections to create a new baseline and/or save new options for future use.\n");
      $out.=sprintf("\nNew Region(s) are available for your selected datacenter(s):\n$delta_sel{'new'}{'region'}\n"), if ($delta_sel{'new'}{'region'});
      $out.=sprintf("\nNew Service(s) are available for your selected datacenter(s):\n$delta_sel{'new'}{'systemservice'}\n"), if ($delta_sel{'new'}{'systemservice'});
      $out.=sprintf("\nRegion(s) have been removed from your selected datacenter(s):\n$delta_sel{'old'}{'region'}\n"), if ($delta_sel{'old'}{'region'});
      $out.=sprintf("\nService(s) have been removed from your selected datacenter(s):\n$delta_sel{'old'}{'systemservice'}\n"), if ($delta_sel{'old'}{'systemservice'});
      $out.=sprintf("\n");
   }

   if ($csv_out) {
      $out.=sprintf("CSV Output for IP changes:\n");
      foreach my $p (keys(%delta_ip)) {
	 foreach my $r (keys(%{$delta_ip{$p}})) {
	    foreach my $s (keys(%{$delta_ip{$p}{$r}})) {
	       if ($delta_ip{$p}{$r}{$s}[0]) {
		  map {$out.=sprintf("$p,$r,$s,New,IPv4,$_\n");} split (/\n/, $delta_ip{$p}{$r}{$s}[0]), if ($ipv4);
	       }
	       if ($delta_ip{$p}{$r}{$s}[1]) {
		  map {$out.=sprintf("$p,$r,$s,New,IPv6,$_\n");} split (/\n/, $delta_ip{$p}{$r}{$s}[1]), if ($ipv6);
	       }
	       if ($delta_ip{$p}{$r}{$s}[2]) {
		  map {$out.=sprintf("$p,$r,$s,Remove,IPv4,$_\n");} split (/\n/, $delta_ip{$p}{$r}{$s}[2]), if ($ipv4);
	       }
	       if ($delta_ip{$p}{$r}{$s}[3]) {
		  map {$out.=sprintf("$p,$r,$s,Remove,IPv6,$_\n");} split (/\n/, $delta_ip{$p}{$r}{$s}[3]), if ($ipv6);
	       }
	    }
	 }
      }
   } elsif ($compress) {
      my %comp; #compress
      $out.=sprintf("Unique IP addresses for your selection parameters\n");
      foreach my $p (keys(%delta_ip)) {
	 foreach my $r (keys(%{$delta_ip{$p}})) {
	    foreach my $s (keys(%{$delta_ip{$p}{$r}})) {
	       map {$comp{"ipv4new"}{$_}=1;} split (/\n/, $delta_ip{$p}{$r}{$s}[0]), if ($ipv4 && $delta_ip{$p}{$r}{$s}[0]); 
	       map {$comp{"ipv6new"}{$_}=1;} split (/\n/, $delta_ip{$p}{$r}{$s}[1]), if ($ipv6 && $delta_ip{$p}{$r}{$s}[1]); 
	       map {$comp{"ipv4rem"}{$_}=1;} split (/\n/, $delta_ip{$p}{$r}{$s}[2]), if ($ipv4 && $delta_ip{$p}{$r}{$s}[2]); 
	       map {$comp{"ipv6rem"}{$_}=1;} split (/\n/, $delta_ip{$p}{$r}{$s}[3]), if ($ipv6 && $delta_ip{$p}{$r}{$s}[3]); 
	    }
	 }
      }
      if (exists($comp{"ipv4new"})) {
	 $out.=sprintf("New IPv4 Addresses:\n");
	 foreach my $ip (keys(%{$comp{'ipv4new'}})) {
	    $out.=sprintf("$ip\n");
	 }
      }
      if (exists($comp{"ipv6new"})) {
	 $out.=sprintf("New IPv6 Addresses:\n");
	 foreach my $ip (keys(%{$comp{'ipv6new'}})) {
	    $out.=sprintf("$ip\n");
	 }
      }
      if (exists($comp{"ipv4rem"})) {
	 $out.=sprintf("Remove the following IPv4 Addresses:\n");
	 foreach my $ip (keys(%{$comp{'ipv4rem'}})) {
	    $out.=sprintf("$ip\n");
	 }
      }
      if (exists($comp{"ipv6rem"})) {
	 $out.=sprintf("Remove the following IPv6 Addresses:\n");
	 foreach my $ip (keys(%{$comp{'ipv6rem'}})) {
	    $out.=sprintf("$ip\n");
	 }
      }
   } else {
      foreach my $p (keys(%delta_ip)) {
	 foreach my $r (keys(%{$delta_ip{$p}})) {
	    foreach my $s (keys(%{$delta_ip{$p}{$r}})) {
	       $out.=sprintf("\n$p\n\t$r\n\t\t$s\n"), if ($delta_ip{$p}{$r}{$s}[0] || $delta_ip{$p}{$r}{$s}[1] || $delta_ip{$p}{$r}{$s}[2] || $delta_ip{$p}{$r}{$s}[3]);
	       if ($ipv4 && $delta_ip{$p}{$r}{$s}[0]) {
		  $out.=sprintf("\nNew IPv4 Addresses:\n");
		  $out.=sprintf("$delta_ip{$p}{$r}{$s}[0]");
	       }
	       if ($ipv6 && $delta_ip{$p}{$r}{$s}[1]) {
		  $out.=sprintf("\nNew IPv6 Addresses:\n");
		  $out.=sprintf("$delta_ip{$p}{$r}{$s}[1]");
	       }
	       if ($ipv4 && $delta_ip{$p}{$r}{$s}[2]) {
		  $out.=sprintf("\nRemove IPv4 Addresses:\n");
		  $out.=sprintf("$delta_ip{$p}{$r}{$s}[2]");
	       }
	       if ($ipv6 && $delta_ip{$p}{$r}{$s}[3]) {
		  $out.=sprintf("\nRemove IPv6 Addresses:\n");
		  $out.=sprintf("$delta_ip{$p}{$r}{$s}[3]");
	       }
	    }
	 }
      }
   } #end if

   return $out;

} #end sub display_delta

#########################################################
sub process_delta {

   my %comp; #complicated data structure to ease comparison of IPs
   #comp{'base/current'}{$p}{$r}{$s}{'ipv4/ipv6'}{$ip address}=1

   foreach my $p (keys(%baseline)) {
      foreach my $r (keys(%{$baseline{$p}})) {
	 $delta_sel{'old'}{'region'}.=sprintf ("$r\n"), unless (exists($data{$p}{$r}));
	 foreach my $s (keys(%{$baseline{$p}{$r}})) {
	    $delta_sel{'old'}{'systemservice'}.=sprintf ("$s\n"), unless (exists($data{$p}{$r}{$s}));
	 }
      }
   }
   foreach my $p (keys(%data)) {
      foreach my $r (keys(%{$data{$p}})) {
	 $delta_sel{'new'}{'region'}.=sprintf ("$r\n"), unless (exists($baseline{$p}{$r}));
	 foreach my $s (keys(%{$baseline{$p}{$r}})) {
	    $delta_sel{'new'}{'systemservice'}.=sprintf ("$s\n"), unless (exists($baseline{$p}{$r}{$s}));
	 }
      }
   }

   foreach my $p (keys(%selected_base)) {
      foreach my $r (keys(%{$selected_base{$p}})) {
	 foreach my $s (keys(%{$selected_base{$p}{$r}})) {
	    $service_delta{$p}{$r}{$s}[2].=sprintf ("$s\n"), if (($selected_base{$p}{$r}{$s} == 2) && ($selected{$p}{$r}{$s} == 1));
	    $service_delta{$p}{$r}{$s}[0].=sprintf ("$s\n"), if ($selected_base{$p}{$r}{$s} == 1);
	 }
      }
   }
   foreach my $p (keys(%selected)) {
      foreach my $r (keys(%{$selected{$p}})) {
	 foreach my $s (keys(%{$selected{$p}{$r}})) {
	    $service_delta{$p}{$r}{$s}[1].=sprintf ("$s\n"), if ($selected{$p}{$r}{$s} == 1);
	 }
      }
   }

   foreach my $p (keys(%baseline)) {
      foreach my $r (keys(%{$baseline{$p}})) {
	 foreach my $s (keys(%{$baseline{$p}{$r}})) {
	    if ($baseline{$p}{$r}{$s}[4]) {
	       map {$comp{'base'}{$p}{$r}{$s}{'ipv4'}{$_}=1;} (split (/\n/, $baseline{$p}{$r}{$s}[2])), if ($baseline{$p}{$r}{$s}[2]);
	       map {$comp{'base'}{$p}{$r}{$s}{'ipv6'}{$_}=1;} (split (/\n/, $baseline{$p}{$r}{$s}[3])), if ($baseline{$p}{$r}{$s}[3]);
	    }
	 }
      }
   }

   foreach my $p (keys(%data)) {
      foreach my $r (keys(%{$data{$p}})) {
	 foreach my $s (keys(%{$data{$p}{$r}})) {
	    if ($data{$p}{$r}{$s}[4]) {
	       map {$comp{'current'}{$p}{$r}{$s}{'ipv4'}{$_}=1;} (split (/\n/, $data{$p}{$r}{$s}[2])), if ($data{$p}{$r}{$s}[2]);
	       map {$comp{'current'}{$p}{$r}{$s}{'ipv6'}{$_}=1;} (split (/\n/, $data{$p}{$r}{$s}[3])), if ($data{$p}{$r}{$s}[3]);
	    }
	 }
      }
   }

   foreach my $p (keys(%{$comp{'current'}})) {
      foreach my $r (keys(%{$comp{'current'}{$p}})) {
	 foreach my $s (keys(%{$comp{'current'}{$p}{$r}})) {
	    foreach my $ip (keys(%{$comp{'current'}{$p}{$r}{$s}{'ipv4'}})) {
	       $delta_ip{$p}{$r}{$s}[0].=sprintf("$ip\n"), unless ($comp{'base'}{$p}{$r}{$s}{'ipv4'}{$ip});
	    }
	    foreach my $ip (keys(%{$comp{'current'}{$p}{$r}{$s}{'ipv6'}})) {
	       $delta_ip{$p}{$r}{$s}[1].=sprintf("$ip\n"), unless ($comp{'base'}{$p}{$r}{$s}{'ipv6'}{$ip});
	    }
	 }
      }
   }

   foreach my $p (keys(%{$comp{'base'}})) {
      foreach my $r (keys(%{$comp{'base'}{$p}})) {
	 foreach my $s (keys(%{$comp{'base'}{$p}{$r}})) {
	    foreach my $ip (keys(%{$comp{'base'}{$p}{$r}{$s}{'ipv4'}})) {
	       $delta_ip{$p}{$r}{$s}[2].=sprintf("$ip\n"), unless ($comp{'current'}{$p}{$r}{$s}{'ipv4'}{$ip});
	    }
	    foreach my $ip (keys(%{$comp{'base'}{$p}{$r}{$s}{'ipv6'}})) {
	       $delta_ip{$p}{$r}{$s}[3].=sprintf("$ip\n"), unless ($comp{'current'}{$p}{$r}{$s}{'ipv6'}{$ip});
	    }
	 }
      }
   }
} #end sub process_delta

#########################################################
sub write_baseline_files {

   my $json=shift;
   my $folder=shift;
   my $date=shift;
   my $p_datacenter=shift;

   my $path_file="${folder}${date}_${p_datacenter}";
   my $file="${date}_${p_datacenter}";

   check_dir_file($folder); #check for existance, if not then create

   open BASELINE, "> $path_file", or logger("Cannot open $path_file for writing!: \"$!\"",1);
   print BASELINE ("$json");
   close BASELINE;
   logger("Wrote raw JSON file named \"$file\" to \"$folder\"",0);
   return "$file";

} #end sub write_baseline_files

#########################################################
sub write_baseline_dat {

   my $file=shift;
   my $name=shift;
   my $a_ref=shift;
   my $ans=shift; #Yes to overwrite (use with --delta), Unknown to prompt user

   my @b_data_contents=@$a_ref;

   check_dir_file($file); #check for existance, if not then create
   if (check_opt_name_exists($file, $name, "#BaselineName:")) {
      logger("Baseline name:\"$name\" already exists in file:\"$file\"",2);
      while (not($ans =~ /(^\s*y\s*$)|(^\s*yes\s*$)|(^\s*n\s*$)|(^\s*no\s*$)/i)) {
	 print "Would you like to overwrite the baseline named \"$name\"? (Y/N): ";
	 chomp($ans=<STDIN>);
      }
      if ($ans =~ /(^\s*y\s*$)|(^\s*yes\s*$)/i) {
	 my %results;
	 logger("Overwriting baseline named: \"$name\" and removing associated JSON files",2);
	 read_baseline($name, \%results, 0);

	 foreach (keys(%results)) {
	    unlink "${azure_baseline_folder}$results{$_}" or logger("Could not remove file: \"${azure_baseline_folder}$results{$_}\": \"$!\" Manual cleanup required!",2);
	 }

	 my $temp_file="${file}.temp";
	 copy("$file","$temp_file") or logger("Could not copy $file to $temp_file: \"$!\"",1);


	 my $content;
	 my $flag=1; #set to 1 to record existing content
	 open TEMP, "< $temp_file", or logger("Cannot open file:\"$temp_file\" for reading!: \"$!\"",1);
	 while (<TEMP>) {
            $flag=0, if (/#BaselineName:"$name"/);
	    if (/#EndBaselineName:"$name"/) {
	       $flag=1; #start recording again
	       next;
	    }
	    $content.=$_, if ($flag);
	 } #end while
	 close TEMP;

	 if ($content) { #if no other baselines present, don't write data
	    open TEMP, "> $file", or logger("Cannot open file:\"$file\" for writing!: \"$!\"",1);
	    print TEMP $content;
	    close TEMP;
	    unlink $temp_file, or logger("Could not remove file: \"$temp_file\": \"$!\" Manual cleanup required!",2);
	 } else {
	    unlink $temp_file, or logger("Could not remove file: \"$temp_file\": \"$!\" Manual cleanup required!",2);
	    unlink "$file" or logger("Could not remove file: \"$file\": \"$!\"",1);
	 }

	 open B_DAT, ">> $file", or logger("Cannot open file:\"$file\" for writing!: \"$!\"",1);
	 print B_DAT "#BaselineName:\"$name\"\n";
	 map {print B_DAT "$_\n"} (@b_data_contents);
	 print B_DAT "#EndBaselineName:\"$name\"\n";
	 close B_DAT;
	 logger("Wrote \"$name\" to \"$file\"",0);
	 return $name;

      } else {
	 print "Choose another name for the baseline: ";
	 chomp(my $new_name=<STDIN>);
	 write_baseline_dat($file, $new_name, \@b_data_contents, "unknown");
      }

   } else {
      open B_DAT, ">> $file", or logger("Cannot open file:\"$file\" for writing!: \"$!\"",1);
      print B_DAT "#BaselineName:\"$name\"\n";
      map {print B_DAT "$_\n"} (@b_data_contents);
      print B_DAT "#EndBaselineName:\"$name\"\n";
      close B_DAT;
      logger("Wrote \"$name\" to \"$file\"",0);
   }
   return "$name";
} #end sub write_baseline_dat

#########################################################
sub read_baseline {

   my $name=shift;
   my $h_ref=shift;
   my $perform_validation=shift; #validate if 1

   my $flag=0; #set flag when you find the correct option
   my $file="$azure_baseline_dat";

   if (check_opt_name_exists($file, $name, "#BaselineName:")) {
      open OPT, "< $file";
      while (<OPT>) {
	 if (/#BaselineName:\"$name\"/) {
	    $flag=1;
	    next;
	 }
	 last, if (/#EndBaselineName:\"$name\"/);
	 if ($flag) {
	    if (/^(.*?_(.*))$/) {
	       $h_ref->{$2}="$1";
	    }
	 }
      } #end while

      logger("Could not find any properly structured options using the name:\"$name\" in file:\"$file\"",1), unless ($flag);
      if ($perform_validation) {
	 foreach my $p (@parent) {
	    unless (exists($h_ref->{$p})) {
	       logger("Selected parent:\"$p\" does not exist within chosen baseline\"$name\" in file:\"$file\"",1);
	    }
	 }
      }
   } else {
      logger("Could not find the baseline \"$name\" in file:\"$file\"",1);
   }

} #end sub read_baseline

#########################################################
sub read_options {

   my $file=shift;
   my $name=shift;
   my $sel=shift; #hash ref for which data structure to use %selected or %selected_base
   my $flag=0; #set flag when you find the correct option

   if (check_opt_name_exists($file, $name,"#OptionName:")) {
      open OPT, "< $file";
      while (<OPT>) {
	 if (/#OptionName:\"$name\"/) {
	    $flag=1;
	    next;
	 }
	 last, if (/#EndOptionName:\"$name\"/);
	 if ((/^([^,]*),([^,]*),([^,\n]*)/) && ($flag)) {
	    $sel->{lc($1)}->{lc($2)}->{lc($3)}=1;
	 }
      } #end while
      logger("Could not find any properly structured options using the name: \"$name\" in file: \"$file\"",1), unless ($flag);
      foreach (keys(%{$sel})) {
	 push (@parent, $_), unless (grep(/^$_$/, @parent));
      }
   } else {
      logger("Could not find the --use_opt: \"$name\" in file: \"$file\"",1);
   }

} #end sub read_options

#########################################################
sub write_options {

   my $file=shift;
   my $option_name=shift;
   my $option_exists;

   check_dir_file($file); #check for existence, if not then create
   $option_exists=check_opt_name_exists($file, $option_name, "#OptionName:"); #see if that option name already exists

   if ($option_exists) {
      #write code to overwrite existing option if selected by user
      logger("Option Name:\"$option_name\" already exists in file \"$file\"",1);
   } else {

      open OPT, ">> $file", or logger("Cannot open $file for appending: \"$!\"",1);
      logger("Creating a new option \"$option_name\" in \"$file\"",0);
      print OPT "#OptionName:\"$option_name\"\n";
      foreach my $p (keys(%selected)) {
	 foreach my $r (keys(%{$selected{$p}})) {
	    foreach my $s (keys(%{$selected{$p}{$r}})) {
	       print OPT "$p,$r,$s\n", if ($selected{$p}{$r}{$s});
	    }
	 }
      }
      print OPT "#EndOptionName:\"$option_name\"\n";
   }

} #end sub write_options

#########################################################
sub check_opt_name_exists {

   my $file=shift;
   my $name=shift;
   my $type=shift;
   
   open OPT, "< $file", or logger("Cannot open $file for reading: \"$!\" Have you created a baseline or option yet?",1);
   while (<OPT>) {
      return 1, if (/^$type\"$name\"/);
   }
   close OPT;
   return 0;

} #end sub check_opt_name_exists

#########################################################
sub csv_import {

   my $csv_import_name=shift;
   $csv_import_name=".\/$csv_import_name", unless ($csv_import_name =~ /\//);

   my $flag=0;

   open IMP, "< $csv_import_name", or logger("Could not open $csv_import_name for reading: \"$!\"",);
   logger("Reading options from $csv_import_name",0);

   while (<IMP>) {
      s/\r//;
      next, if (/\bParent,/i); #skip csv header
      if (/^([^,]*),([^,]*),([^,\n]*)/) {
	 $selected{lc($1)}{lc($2)}{lc($3)}=1;
	 $flag=1; #found at least one option
      }
   } #end while

   close IMP;
   logger("No options were found in the imported file $csv_import_name",1), unless ($flag);

} #end sub csv_import

#########################################################
sub check_dir_file {

   my $full_path=shift;
   my $file=$1, if ($full_path =~ /.*[\/\\](.*)/);
   my $dir=$1, if ($full_path =~ /(.*[\/\\])/);
   #print "Full_path:\"$full_path\", File:\"$file\", Dir:\"$dir\"\n";
   
   unless ($dir && (-d $dir)) {
      print STDERR "$dir does not exist!\nCreating $dir\n";
      die "Unabled to create $dir: \"$!\"\n", unless (mkdir ($dir)); 
   }

   unless (-e $full_path) {
      print STDERR "${dir}$file does not exist!\nCreating $file in $dir\n";
      die "Unable to create $file in $dir: \"$!\"\n", unless (open NEWFILE, ">$full_path"); 
      close NEWFILE;
   }

} #end sub check_dir_file

#########################################################
sub build_display {

my $h_ref=shift;

my $printable; #used for sprintf to build all output for easier modification

unless ($csv_out) {
   $printable.=sprintf ("%s%s\n\n", "Parent\n\tRegion\n\t\tSystemService\n", "="x29), unless ($compress);
} else {
   $printable.=sprintf ("Parent,Region,Service,IP Protocol,IP Address\n"), unless ($compress);
}

foreach my $p (keys(%selected)) {

   foreach my $r (keys(%{$selected{$p}})) {

      foreach my $s (keys(%{$selected{$p}{$r}})) {
	 if ($h_ref->{$p}->{$r}->{$s}[4]) {

	    if ($compress) {
	       map {$compress{"ipv4"}{$_}=1;} split (/\n/, $h_ref->{$p}->{$r}->{$s}[2]), if ($ipv4 && (exists($h_ref->{$p}->{$r}->{$s}[2]))); 
	       map {$compress{"ipv6"}{$_}=1;} split (/\n/, $h_ref->{$p}->{$r}->{$s}[3]), if ($ipv6 && (exists($h_ref->{$p}->{$r}->{$s}[3])));
	    } elsif ($csv_out) {
	       map {$printable.=sprintf ("$p,$r,$s,IPv4,$_\n");} split (/\n/,$h_ref->{$p}->{$r}->{$s}[2]), if ($ipv4 && (exists($h_ref->{$p}->{$r}->{$s}[2])));
	       map {$printable.=sprintf ("$p,$r,$s,IPv6,$_\n");} split (/\n/,$h_ref->{$p}->{$r}->{$s}[3]), if ($ipv6 && (exists($h_ref->{$p}->{$r}->{$s}[3])));
	    } else {
	      $printable.=sprintf ("$p\n\t$r\n\t\t$s\n"); #print the header for standard display output

	      if ($ipv4 && (exists($h_ref->{$p}->{$r}->{$s}[2]))) {
		 $printable.=sprintf ("IPv4\n");
		 $printable.=sprintf ("$h_ref->{$p}->{$r}->{$s}[2]\n");
	      }

	      if ($ipv6 && (exists($h_ref->{$p}->{$r}->{$s}[3]))) {
		 $printable.=sprintf ("IPv6\n");
		 $printable.=sprintf ("$h_ref->{$p}->{$r}->{$s}[3]\n");
	      }

	    } #end nested if
	    
	 } #end parent if
      } #end nest nest foreach
   } #end nested foreach
} #end parent foreach

if ($compress) {

   if ($ipv4) {
      $printable.=sprintf ("%s%s\n", "Unique IPv4 Addresses based on the selected scope\n", "="x49);
      foreach (keys(%{$compress{"ipv4"}})) {
	 $printable.=sprintf ("$_\n");
      }
   }

   if ($ipv6) {
      $printable.=sprintf ("\n%s%s\n", "Unique IPv6 Addresses based on the selected scope\n", "="x49);
      foreach (keys(%{$compress{"ipv6"}})) {
	 $printable.=sprintf ("$_\n");
      }
   }

} #end if

return $printable;

} #end build_display sub 

#########################################################
sub build_selection {

   my $type=shift; #options are "cli" or "options"
   my $dat=shift; #either %data or %baseline hash reference
   my $sel=shift; #either %selected or %selected_base hash reference
   my $scope=shift; #"baseline" or "current"

   $scope="current", unless ($scope);

   if ($type eq "cli") {
      foreach my $p (keys(%{$dat})) {
	 foreach my $r (keys(%{$dat->{$p}})) {
	    foreach my $s (keys(%{$dat->{$p}->{$r}})) {
	       $sel->{$p}->{$r}->{$s}=0;
	    }
	 }
      }
      $_=lc($_), foreach (@region);
      $_=lc($_), foreach (@service);

      foreach my $p (keys(%{$sel})) {
	 if ($region[0] eq "all") {
	    foreach my $r (keys(%{$sel->{$p}})) {
               if ($service[0] eq "all") {
		  foreach my $s (keys(%{$sel->{$p}->{$r}})) {
		     $sel->{$p}->{$r}->{$s}=2;
		     $dat->{$p}->{$r}->{$s}[4]=1;
		  }
	       } else { #user chose --service options on CLI
		  foreach my $s_sel (@service) {
		     if (exists($sel->{$p}->{$r}->{$s_sel})) {
			$sel->{$p}->{$r}->{$s_sel}=2;
			$dat->{$p}->{$r}->{$s_sel}[4]=1;
		     } else {
			$sel->{$p}->{$r}->{$s_sel}=1;
			logger("JSON Source input for $scope did not contain the service \"$s_sel\" in $p\->$r",2);
		     }
		  }
	       }
	    }
	 } else { #user chose --region options on CLI
	    foreach my $r_sel (@region) {
	       if (exists($sel->{$p}->{$r_sel})) {
		  if ($service[0] eq "all") {
                     foreach my $s (keys(%{$sel->{$p}->{$r_sel}})) {
			$sel->{$p}->{$r_sel}{$s}=2;
                        $dat->{$p}->{$r_sel}->{$s}[4]=1;
		     }
		  } else { #user chose --service options on CLI
		     foreach my $s_sel (@service) {
			if (exists($sel->{$p}->{$r_sel}->{$s_sel})) {
			   $sel->{$p}->{$r_sel}->{$s_sel}=2;
			   $dat->{$p}->{$r_sel}->{$s_sel}[4]=1;
			} else {
			   $sel->{$p}->{$r_sel}->{$s_sel}=1;
			   logger("JSON Source input for $scope did not contain the service \"$s_sel\" in $p\->$r_sel",2);
			}
		     }  
		  }  
	       } else { #user selected region does not exist
	         logger("JSON Source input for $scope did not the region \"$r_sel\" in parent \"$p\"",2);
	       }
	    }  
	 }  
      }
   } elsif ($type eq "options") {
      foreach my $p (keys(%{$sel})) {
         foreach my $r (keys(%{$sel->{$p}})) {
	    foreach my $s (keys(%{$sel->{$p}->{$r}})) {
	       if (exists($dat->{$p}->{$r}->{$s})) {
                  $sel->{$p}->{$r}->{$s}=2;
		  $dat->{$p}->{$r}->{$s}[4]=1;
               } else { 
		  $sel->{$p}->{$r}->{$s}=1;
		  logger("JSON Source input for $scope did not contain the selction for $p\->$r\->$s",2);
	       }
	    }
	 }
      }
   } #end parent if

} #end build_selection sub

#########################################################
sub print_show {

   my $h_ref=shift;

   my $r_flag=0; #used to print region once for non-csv output

   if ($csv_out) {
      print "Parent,Region,SystemService\n";
   } else {
      print "Parent\n\tRegion\n\t\tSystemService\n\n";
   }

   foreach my $p (keys(%selected)) {
      print "$p\n", unless ($csv_out);

      foreach my $r (keys(%{$selected{$p}})) {
	 $r_flag=1; 

	 foreach my $s (keys(%{$selected{$p}{$r}})) {
	    if (($r_flag) && ($h_ref->{$p}->{$r}->{$s}[4])) {
	       $r_flag=0;
	       if ($csv_out) {
		  print "$p,$r,$s\n";
	       } else {
		  print "\t$r\n";
		  print "\t\t$s\n";
	       }
	    } elsif ($h_ref->{$p}->{$r}->{$s}[4]) {
	       if ($csv_out) {
		  print "$p,$r,$s\n";
	       } else {
		  print "\t\t$s\n";
	       }
	    }
	 }
      }
   } #end parent foreach

} #end print_show sub

#########################################################
sub pre_process_cli_selections {

   unless (@parent) { #validate parent
      $parent[0]="public";
   } else {
      foreach (@parent) {
	 my $t=lc($_);
	 if ($t =~ /^all$/) {
	    @parent=(keys(%parent_loc_def));
	    last;
	 }
	 logger("\"$_\" is not a defined datacenter. Use \"$0 --help\" to see a list of available options",1), unless (exists($parent_loc_def{$t}));
      }
   }

   $region[0]="all", unless (@region);
   $service[0]="all", unless (@service);

} #end pre_process_cli_selections sub

#########################################################
sub retrieve_ip {

   my $p_loc=shift;

   my $agent=LWP::UserAgent->new(ssl_opts => {verify_hostname => 0});
   my $request=HTTP::Request->new, or logger("Cannot send request to $url_azure: \"$!\"",1);
   logger("Sending HTTPS request to $url_azure",0);
   $request=$agent->get ("$url_azure");
   my $dl_url=$request->content;
   logger("Obtained content from $url_azure",0);
   
   if ($dl_url=~ /$p_loc/i) { #capture is defined in $p_loc
      $dl_url=$1;
      $request=$agent->get ("$dl_url");
      logger("Downloading $dl_url from $url_azure",0);
      return($request->content);
   } else {
      logger("Was not able to find the expected file reference in the content from the URL:${url_azure}. Check $github_loc for the latest version of $0",1);
   }

} #End sub for retrieving IP addresses

#########################################################
sub parse_download {
   
my $raw=shift; #input
my $p=shift; #parent
my $h_ref=shift; #hash to populate with the data

my $change_num_parent;
my $change_num_child;

my $cloud_type;
my $name; #ID and Name in input appear to be identical
my $id;
my $region;
my $regionID; #will just use region
my $platform; #all platforms are Azure
my $systemservice;
my $flag=0; #when 1, then processes list of tags preceeding IPs
my $flag2=0; #when 1, then processes list of IPs
my $found_ip=0; #1, when find at least 1 ip address

open my $fh, '<', \$raw, or logger("Cannot read values from JSON: \"$!\"",1);
logger("Parsing JSON for $p",0);

while (<$fh>) {

   if (/"networkFeatures":/) { #not capturing network features, but use it to reset the flags
      $flag2=0;
      next;
   }

   if ($flag2) {
      if (/"(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\/\d+)"/) { #found an IPv4 address
	 $h_ref->{$p}->{$region}->{$systemservice}[2].=sprintf("$1\n");
	 $h_ref->{$p}->{$region}->{$systemservice}[0]=$change_num_child;
	 $h_ref->{$p}->{$region}->{$systemservice}[1]="$name";
	 $found_ip=1;
	 next;
      } elsif (/"([:\da-f]{4,}\/\d+)"/i) {
	 $h_ref->{$p}->{$region}->{$systemservice}[3].=sprintf("$1\n");
	 $h_ref->{$p}->{$region}->{$systemservice}[0]=$change_num_child;
	 $h_ref->{$p}->{$region}->{$systemservice}[1]="$name";
	 $found_ip=1;
	 next;
      }
   } #end nested IF on $flag2


   if ($flag) {
      if (/"region":\s*"(\w*)",/) {
	 my $t=$1;
	 $t=lc($t);
	 if ($t=~/^\s*$/) {
	    $region="common";
	 } else {
	    $region=$t;
	 }
	 next;
      }

      if (/"name":\s+"(\w*)",/) {
	 $name=$1;
	 next;
      }

      if (/"regionID":\s*(\d*)/) {
	 $regionID=$1;
	 next;
      }

      if (/"platform":\s*"(\w*)",/) {
	 $platform=$1;
	 next;
      }

      if (/"changeNumber":\s*(\d*),/) { #identical regex for parent, need to ensure proper flag setting to protect
	 $change_num_child=$1;
	 next;
      }

      if (/"systemService":\s*"(\w*)",/) {
	 my $t=$1;
	 $t=lc($t);
	 if ($t=~/^\s*$/) {
	    $systemservice="commonservice";
	 } else {
	    $systemservice=$t;
	 }
	 next;
      }

      if (/"addressPrefixes":\s*\[/) {
	 $flag2=1;
	 next;
      }
         
   } #end nested IF on $flag

   if (/"properties": \{/) {
      $flag=1;
      next;
   }

   if (/"changeNumber":\s*(\d+),/) {
      $change_num_parent=$1;
      next;
   }

   if (/"cloud":\s*"(\w*)",/) {
      $cloud_type=$1;
      next;
   }

   if (/"name":\s*"(\w*)",/) {
      $name=$1;
      next;
   }

   if (/"id":\s*"(\w*)",/) {
      $id=$1;
      next;
   }

} #end while

close $fh;
logger("Completed parsing for $p",0);
logger("Could not find any IP addresses in the raw JSON, try downloading the latest version of this program from $github_loc",2), unless ($found_ip);

} #end sub parse_download

#########################################################
sub usage {
   my $p_loc;
   map {$p_loc.=sprintf ("%s, ", $_)} (keys(%parent_loc_def));
   $p_loc.=sprintf("%s", "all");
   print "\nPurpose:\n\n";
   printf "%s\n\n", "Provide the capability to display IPv4 or IPv6 addresses related to Microsoft's Azure datacenter services. ".
   "Create a baseline of active IPs and compare against that baseline to find IP address changes, or changes to regions or services. ".
   "Output can be sent to an external program for e-mail notification, but log files and delta reports are also generated based on each call".
   " to create a baseline or view a change in case a notification was missed. ".
   "Run this program to determine the available data centers, regions, and services.  Then display the IPv4 or IPv6 addresses that are currently in use. ".
   "When satisfied on the scope of services selected, create a baseline based on those parameters. ".
   "Finally, run this program from a cron or scheduled service to output the delta's and create a new baseline if changes were detected.";

   print "\n  Usage:\n";
   print "\t--help\t\tThis output for usage information\n\n";

   print "\t--parent\tDefaults to \"Public\". Choose the primary datacenter location (space separated list can be provided on the command line for multiple datacenters, or all)\n";
   print "\t\t\tAvailable options are: \"$p_loc\"\n\n";

   print "\t--region\tDefaults to \"All\". Choose available regions (space separated list can be provided on the command line for multiple regions)\n\n";

   print "\t--service\tDefaults to \"All\". Choose available services (space separated list can be provided on the command line for multiple services)\n\n";

   print "\t--show\t\tSets a flag to show available parents, regions, and services to filter on for use with the other options\n\n";

   print "\t--display\tSets a flag to display the IPs based on the parent, region, service. Additional options are IPv4/IPv6 and output can be compressed, CSV, or default\n\n";

   print "\t--csv\t\tSets a flag to output content in CSV (Comma Separated Values) format\n\n";

   print "\t--compress\tSets a flag to only show unique IP addresses rather than displaying likely duplicates under each parent, region, and service\n\n";
   
   print "\t--ipv4\t\tSets a flag to only provide IPv4 addresses that are responsive to the parent, region, and service (can be combined with --ipv6)\n\n";

   print "\t--ipv6\t\tSets a flag to only provide IPv6 addresses that are responsive to the parent, region, and service (can be combined with --ipv4)\n\n";

   print "\t--import_csv\tMust be used with --use_opt. Provide a quoted string containing the path and filename of the csv to import selected options for more granular and easier configuration\n";
   print "\t\t\tFirst run --show with \"--parent all --csv\" and filter the results to options that are desired. Then import to save those options in \"$azure_opt\"\n\n";

   print "\t--set_opt\tProvide a quoted string to save the options (parent, region, service) using the file $azure_opt to a name (case insensitive) set in --import_csv or on the CLI to $azure_opt\n";
   print "\t\t\tCan only be used with the following options \"--parent --region --service or --import_csv\"\n\n";

   print "\t--use_opt\tProvide a quoted string to read the options (parent, region, service) using the stored name in file $azure_opt)\n";
   print "\t\t\tCan only be used with the following options \"--import_csv --display --delta --create_baseline --use_baseline --show\"\n\n";

   print "\t--delta\t\tSets a flag to compare selected baseline (--use_baseline) against the current state by using either the options chosen from --use_opt or the CLI.\n";
   print "\t\t\tCan be combined with --create_baseline to display the delta and either create a new baseline or overwrite the existing depending on the name provided.\n\n";

   print "\t--create_baseline\tProvide a quoted string containing the baseline file name to create.  Create a new baseline on based on the selected parent.\n";
   print "\t\t\t\tCreates an entry in $azure_baseline_dat and writes the raw JSON files to the following directory $azure_baseline_folder.\n";

   print "\n  Examples:\n";
   print "\t$0 --show --parent public --region eastus2 --csv\n";
   print "\t\tShows all available \"services\" for the Public cloud in the eastus2 region in CSV format. (Use this format to filter in your favorite spreadsheet and import to save your selection)\n\n";
   print "\t$0 --display --parent all --region all --service AzureStorage --service AzureSQL --ipv4\n";
   print "\t\tDisplays all IPv4 address currently in use for all clouds and all regions, if they are tagged as an AzureStorage and AzureSQL service\n\n";
   print "\t$0 --display --create_baseline \"new_baseline_filename\" --parent government --region uswest --compress\n";
   print "\t\tCreates a new file in the baselines subdirectory based on the name provided that contains the current state based on your selection of government cloud and all services in the uswest region\n";
   print "\t\tAdditionally, the IP addresses are \"compressed\" so that no duplicate IPs are displayed (Easier updates for network configurations)\n";
   print "\t$0 --display --delta --use_baseline \"existing baseline file name\"\n";
   print "\t\tDisplays the delta's based on the options stored in the selected baseline from the corresponding file(s) in the baseline subdirectory\n\n";
} #end sub usage

