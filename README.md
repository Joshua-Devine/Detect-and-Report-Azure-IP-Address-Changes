# Detect and Report Azure IP Address Changes
Perl script that will query an [external website](https://azservicetags.azurewebsites.net/) to download and filter on data centers, regions, and services available from the Microsoft Azure cloud services in order to report on published IPv4 and IPv6 addresses.  Create named baselines based on selected parameters in order to display IP address changes so that layer 3/4 boundary devices can be proactively configured to avoid service disruption.  After the environment is configured with the necessary system packages and libraries, the program does not need any elevated permissions to run.

## Installation Requirements
The [Perl Script](https://github.com/Joshua-Devine/Detect-and-Report-Azure-IP-Address-Changes/blob/main/azure_datacenter_ip.pl) has been tested on Windows WSL and Ubuntu installations and requires the following Packages and Perl libraries to be installed.

### Ubuntu System Packages
Here are the following Ubuntu system packages necessary to allow proper installation of the Perl libraries
```
cpanminus
build-essential
libwww-perl
libssl-dev
lib32z1-dev
```

Use the following command to install all system packages on Ubuntu
```
sudo apt update && sudo apt install cpanminus build-essential libwww-perl 
```

### Perl Libraries
The following Perl libraries required
```
Getopt::Long
LWP::UserAgent
LWP::Protocol::https
LWP::Simple
Date::EzDate
File::Copy
```

Use the following command to install all necessary Perl libraries and dependencies:
```
sudo cpanm Getopt::Long LWP::UserAgent LWP::Protocol::https LWP::Simple  Date::EzDate File::Copy
```

## Typical Workflow
Here is the general outline on how this program should be utilized.
1. Determine what selections are required for your utilization of Azure cloud services.
    1. Choose your datacenter(s) using --parent.  Options are "All, Public, Government, Germany, and China", multiple selections are permitted.
    2. Use --show and --csv with your --parent selection to generate a CSV output for filtering the available --regions and --services to meet your requirements.
    3. Import and save your options using --import_csv and --set_opt for future queries.
4. Create a baseline based on your selections.
    1. Use --create_baseline and --use_opt (or CLI options) to create a named baseline for a snapshot of the existing state.
    2. Multiple baselines can be created by calling the program again and providing a different name.
3. Use the baseline to detect any IP address changes.
    1. Using a baseline must include options (saved or CLI).  Note it is NOT recommended changing options from the initial baseline creation and running --delta that compares that baseline against the current state.
    2. Use the same options when creating a baseline and performing a comparison.  This includes the use of --ipv4 and/or --ipv6 for consistent and reliable output.
2. Automate the program to notify stakeholders of IP address changes.
    1. Run the program as a cron job to routinely check for IP address changes.
    2. Save the program output to a file to be used for your preferred method of sending a notification. (E.g., Have a separate cron job running Sendmail to read the outputted data into the body of an e-mail message.)
    3. Choose to either manually update the baseline, or automatically update the baseline.
        1. The manual method will result in displaying the IP changes on each program execution, until a new baseline is created.
        2. The automatic method will overwrite the existing baseline on each program call after displaying IP changes. (Use --create_baseline "name of baseline" with --use_baseline "name of baseline)

## Basic Usage

Display usage information:

`./azure_datacenter_ip.pl --help`

Select which Azure datacenter(s) are applicable to your environment and **show** all available regions and services that are available.  Parent will default to 'Public' but the available options are: 'All, Public, Germany, Government, and China'

`./azure_datacenter_ip.pl --parent public germany --show`

Sample output:
```
Parent
        Region
                SystemService

germany
        common
                azuresiterecovery
                azurebackup
                azureiothub
                azureconnectors
...continued (2,000+ additional lines)
```

Format the output for easier manipulation and filtering:

`./azure_datacenter_ip.pl --show --parent public germany --csv`

Sample output:
```
Parent,Region,SystemService
public,uaecentral,hdinsight
public,uaecentral,azureservicebus
public,uaecentral,azuredataexplorermanagement
public,uaecentral,azuremachinelearning
...
```

*Note: Recommend writing the CSV output to a file to filter the results to only the datacenter(s), region(s), and service(s) that are responsive to your use of Azure cloud services.  (See the option --import_csv "csvfile.csv" below) to save those options to a user-provided name.*

**Display** the IP addresses that are currently in use, after the selections (datacenter(s), region(s), service(s)) are determined. 

`./azure_datacenter_ip.pl --display --ipv4 --parent public --region eastus westus --service actiongroup azuredevops commonservice`

Sample output:
```
public
        eastus
                azuredevops
IPv4
20.42.5.0/24

public
        eastus
                commonservice
IPv4
13.68.128.0/17
13.72.64.0/18
```

Only display the unique IPv4 and/or IPv6 addresses that are in use for easier importing into your network device(s) by using **--compress**.

`./azure_datacenter_ip.pl --display --ipv4 --compress --parent public --region eastus westus --service actiongroup azuredevops commonservice`

Sample output:

```
Unique IPv4 Addresses based on the selected scope
=================================================
52.152.128.0/17
20.85.128.0/17
168.61.0.0/19
52.101.52.0/22
168.62.192.0/19
...
```

*Note: Command Line Interface (CLI) definition(s) of --**region** and --**service** will apply to all of the selected scope.  E.g., Choosing the service named "AzureDevOps" will bring it into scope for **all** chosen regions and datacenters selected, which may not have the granularity that is desired.  Instead, use --import_csv and --set_opt "my options" to set your specificity.*

**Save** your CLI selection to a user defined name using --**set_opt** "user defined name".  Multiple options can be defined and recalled.
`./azure_datacenter_ip.pl --set_opt "my options" --parent public --region eastus westus --service actiongroup`

**Save** your CSV selections using --**import_csv** "./my_csvselections.csv" and --**set_opt** "My Options"

`./azure_datacenter_ip.pl --import_csv "my_csvselections.csv" --set_opt "my options"`

**Use** your saved selections using --**use_opt** "my options".

`./azure_datacenter_ip.pl --use_opt "my options" --display --ipv4 --compress`

**Create a baseline** using --**create_baseline** "new baseline" using your selection or saved options.  A baseline creates a point in time snapshot to display IPs based on your selected options based on the historical data.  Baselines are primarily used with --**delta** described below.

Building a baseline using stored options:

`./azure_datacenter_ip.pl --use_opt "my options" --create_baseline "new baseline"`

Buiding a baseline using CLI options. (*Note: Less granular*)

`./azure_datacenter_ip.pl --create_baseline "new baseline" --parent public --region eastus westus --service actiongroup azuredevops commonservice`

**Use a baseline** using --**use_baseline** "new baseline" to --show --display, or --delta options based on options selected on the CLI or saved options.

`./azure_datacenter_ip.pl --use_baseline "new baseline" --use_opt "my options" --display --ipv4 --ipv6`

**IP Changes:** To display IP address changes, use --**delta** with chosen options. Must be used with --use_baseline.  Compatible with --create_baseline, --ipv4, --ipv6, --csv, and --compress.

`./azure_datacenter_ip.pl --delta --use_baseline "new baseline" --use_opt "my options" --ipv4 --ipv6 --compress`

**IP Changes and create new baseline:** When running this program from a scheduled job (cron) consider using --create_baseline to automatically overwrite the named baseline after the program provides the IP changes.

`./azure_datacenter_ip.pl --delta --use_baseline "new baseline" --create_baseine "new baseline" --use_opt "my options" --ipv4 --ipv6 --compress`

## Program Environment

The program will create various files and folders within the working directory to function.

**./logs/azure_ip.log** -
Contains log files that are generated during the execution of the script.  The command issued, what functions are called, warning messages, and error messages.

**./baseline/YYYY-MM-DD-epoch_in_seconds_datacenter** -
Stores the raw JSON file(s) downloaded from "https://azservicetags.azurewebsites.net/" when --create_baseline is used.

**./data/azure_ip.opt** - File containing all stored options.  Used when setting or using user defined options.

**./data/azure_ip.bas** - File containing all stored baselines names and the associated JSON file stored in ./baseline/

**./report/YYYY-MM-DD-epoch_in_seconds** - Contains all program output when --delta is called in case a notification was missed.


