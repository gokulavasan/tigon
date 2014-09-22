#! /usr/bin/perl -w

# ------------------------------------------------
#   Copyright 2014 AT&T Intellectual Property
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
# -------------------------------------------

use Cwd;

sub GetProcess;
sub KillAll;
sub Ps;
sub ExitWithError;
sub Die;
sub LogMessage;

$| = 1;

use constant { SUCCESS => 0, FAILURE => 1, SYSERROR => 2, TIMESTAMP => 3, NO_TIMESTAMP => 4 };
%ErrorStrings = ( SUCCESS => "Success", FAILURE => "Failure", SYSERROR => "SystemError",
                  0 => "Success", 1 => "Failure", 2 => "SystemError" );
$ID=`id -un`;
chomp $ID;

$TestName = "TestTypes";

$PWD = cwd();
($STREAMING) = $PWD =~ /^(.*\/STREAMING\b)/;
$STREAMING="$ENV{HOME}/STREAMING" if ( ! defined $STREAMING );
Die "Could not identify STREAMING directory." if ( ! -d $STREAMING );
$STREAMING_TEST="$STREAMING/test";
$ROOT="$STREAMING_TEST/$TestName";
%Months = ( 1 => "Jan",
            2 => "Feb",
            3 => "Mar",
            4 => "Apr",
            5 => "May",
            6 => "Jun",
            7 => "Jul",
            8 => "Aug",
            9 => "Sep",
            10 => "Oct",
            11 => "Nov",
            11 => "Dec" );

$ExitCode = SUCCESS;
$Exceptions = 0;
my $LogFile;
{
    my ($Second,$Minute,$Hour,$DayOfMonth,$Month,$Year) = localtime();
    $Year += 1900;
    $Month += 1;
    $LogFile= sprintf("$STREAMING_TEST/test_results_%04d-%02d-%02d.txt",
                      $Year, $Month, $DayOfMonth);
}

$GID = getpgrp($$);
LogMessage( "Starting: <$TestName>", NO_TIMESTAMP );

Die "File $STREAMING_TEST/$TestName/packet_schema_test.txt is expected." unless ( -f "$STREAMING_TEST/$TestName/packet_schema_test.txt" );
if ( system("cp", "-p", "$STREAMING_TEST/$TestName/packet_schema_test.txt", "$STREAMING/cfg/packet_schema_test.txt") )
{
    Die "Could not copy packet_schema_test.txt into $STREAMING/cfg";
}

chdir "$ROOT" or Die "Could not change directory to $ROOT: $!";
opendir DIR, "." or Die "Could not open current directory for read.";
@DirectoryList = readdir DIR;
closedir DIR;
@DataTypes=();

foreach my $Item ( @DirectoryList )
{
    if ( $Item eq "." or $Item eq ".." ) { next; }
    if ( -d $Item and ! -l $Item )
    {
        push @DataTypes, $Item;
    }
}

if ( @ARGV == 1 and -d $ARGV[0] )
{
    @DataTypes=@ARGV;
}
elsif ( @ARGV > 1 or (@ARGV == 1 and ! -d $ARGV[0]) )
{
    Die "Invalid arguments @ARGV.";
}

open FILE, "$STREAMING/bin/gshub.py" or Die "Could not open file $STREAMING/bin/gshub.py for read.";
$Python = <FILE>;
close FILE;
($Python) = $Python =~ /^\#\!(.+)$/g;

$TypeCount = 0;
foreach my $DataType (@DataTypes)
{
    if ( $TypeCount++ > 0 )
    { LogMessage "===============================================================", NO_TIMESTAMP; }
    my $TypeQueryName = undef;
    chdir "$ROOT/$DataType" or Die "Could not change directory to $ROOT/$DataType: $!";
####    LogMessage "Working on type $DataType in $ROOT/$DataType.";
    LogMessage "Starting: <$TestName/$DataType>", NO_TIMESTAMP;
    
    opendir DIR, "." or Die "Could not open include directory for read.";
    my @DirectoryList = readdir DIR;
    closedir DIR;
    @Queries = ();
    foreach my $Item ( @DirectoryList )
    {
    
        if ( $Item eq ".." or $Item eq "." ) {next;}
        if ( $Item =~ /^[a-zA-Z_0-9]+\.gsql/ )
        {
            push @Queries, $Item;
        }
    }
    open OUTSPEC, ">output_spec.cfg" or Die "Could not open file output_spec.cfg for write.";
    foreach my $QueryFile ( @Queries )
    {
        open FILE, "$QueryFile" or Die "Could not open query file $QueryFile.";
        my $QueryName = undef;
        while (<FILE>)
        {
            if ( $_ =~ /^query_name / )
            {
                ($QueryName) = $_ =~ /^query_name +'([a-zA-Z_0-9]+)'/;
                if ( defined $QueryName ) { last; }
            }
        }
        close FILE;
        Die "Could not extract the query name from $QueryFile." unless defined $QueryName;
        print OUTSPEC "${QueryName},stream,,,,,\n";
        if ( $QueryFile eq "type_${DataType}.gsql" )
        {
            $TypeQueryName = ${QueryName};
        }
    }
    close OUTSPEC;

    Die "Could not locate the expected query files in $ROOT/$DataType."
        if ( ! defined $TypeQueryName or @Queries != 1 );

    opendir DIR, "." or Die "Could not open current directory for read.";
    @DirectoryList = readdir DIR;
    closedir DIR;
    foreach my $File ( @DirectoryList )
    {
        if ( ! -f $File or $File !~ /^[0-9]+.txt/ ) {next;}
        Die "Could not remove file $File." unless unlink($File) == 1;
    }
    foreach my $FileToDelete qw( CumulativeInput.txt Output.txt envy4.research.att.com_lfta.c gswatch.pl hfta_0 hfta_0.cc hfta_0.o lfta.o Makefile postopt_hfta_info.txt preopt_hfta_inf qtree.xml rts runit set_vinterface_hash.bat stopit internal_fcn.def external_fcns.def )
    {
        foreach my $File ( @DirectoryList )
        {
            if ( $File eq $FileToDelete )
            {
                Die "Could not remove file $File" unless unlink($File) == 1;
                last;
            }
        }
    }

    if ( system("$STREAMING/bin/buildit_test.pl > buildit.out 2>&1") or ! -f "rts" or ! -f "lfta.o" )
    {
        LogMessage "buildit for $DataType failed.", SYSERROR;
        LogMessage "Ending: <$TestName/$DataType> <$ErrorStrings{SYSERROR}>", NO_TIMESTAMP;
        next;
    }
    LogMessage "buildit in $ROOT/$DataType successful.";
    KillAll;
    Die "Could not remove file gs.pids" if ( -f "gs.pids"  && unlink("gs.pids") != 1 );

#    my $RC = system("./runit > run.out 2>&1");

	my $pid = fork();
	if (not defined $pid) {
   		die 'Unable to fork child process';
	} elsif ($pid == 0) {
    # CHILD
		setpgrp;
    	exit system("./runit > run.out 2>&1");
	} else {
   		wait;
    	$RC = $?;
	}


    if ( $RC != 0 )
    {
        LogMessage "runit returned error $RC.", SYSERROR;
        LogMessage "Ending: <$TestName/$DataType> <$ErrorStrings{SYSERROR}>", NO_TIMESTAMP;
        next;
    }

    sleep 10;
    if ( ! open GSHUB, "gshub.log" )
    {
        my $Message = "Could not open file gshub.log";
        if ( ! -f $Python or ! -x $Python )
        {
            $Message = $Message . " as $Python does not exist.";
        }
        Die "$Message\nPlease make sure you have python 3.x installed and firewall is configured to allow opening port to listen to HTTP requests.";
    }
    my $IP = <GSHUB>;
    close GSHUB;
    chomp($IP);
    if ( length($IP) < 10 )
    {
        LogMessage "Can not find hub ip in $ROOT/$DataType.", SYSERROR;
        LogMessage "Ending: <$TestName/$DataType> <$ErrorStrings{SYSERROR}>", NO_TIMESTAMP;
        next;
    }

    print "${STREAMING}/bin/gsgdatprint $IP default $TypeQueryName\n";
    system("${STREAMING}/bin/gsgdatprint $IP default $TypeQueryName > gsgdatprint.out 2>&1&");

    sleep 10;
    open FILE, ">gen_feed" or Die "Could not open file gen_feed for write.";
    print FILE q(#!/usr/bin/perl
$ii = 0;
system("rm -f cumulativeInput");
if ( ! -f "Input.txt" ) { print STDERR "File Input.txt is expected $PWD.\n"; exit 1; }
while($ii< 9) {
while(-e "exampleCsv") {sleep(1); }
open A, "<Input.txt";
open B, ">exampleCsvX";
++$ii;
while (<A>)
{
 $x = "$ii|$_";
 print B $x;
}
system("cat exampleCsvX >> CumulativeInput.txt");
system("mv exampleCsvX exampleCsv");
sleep 1;
}
);
    close FILE;
    Die "Could not chmod on $ROOT/$DataType/gen_feed." unless chmod(0777, "gen_feed") == 1;
    system("./gen_feed 2>&1&");
    sleep 1;
    Die "Could not run gen_feed." unless Ps("gen_feed") == 1;
    Ps;
    sleep 60;
    KillAll;

    opendir DIR, "." or Die "Could not open current directory for read.";
    @DirectoryList = readdir DIR;
    closedir DIR;
    my @DataFiles = ();
    foreach my $Item ( @DirectoryList )
    {
        if ( $Item =~ /^[0-9]+.txt$/ ) { push @DataFiles, $Item; }
    }

    if ( @DataFiles == 0 )
    {
        LogMessage "Can not locate text files expected from gsgdatprint for $DataType.", FAILURE;
        LogMessage "Ending: <$TestName/$DataType> <$ErrorStrings{FAILURE}>", NO_TIMESTAMP;
        next;
    }

    $DiffChecked=0;
    if ( ! -f "CumulativeInput.txt" )
    {
        LogMessage "Could not locate file CumulativeInput.txt in $ROOT/$DataType.", SYSERROR;
        LogMessage "Ending: <$TestName/$DataType> <$ErrorStrings{SYSERROR}>", NO_TIMESTAMP;
        next;
    }
    open FILE, "CumulativeInput.txt" or Die "Could not open CumulativeInput.txt for read.";
    my $ExpectedLineCount = 0;
    my ($ExpectedContent, @ExpectedContent);
    while (<FILE>)
    {
        my @InputElements = split /\|/;
        if ( $InputElements[0] eq "1" )
        {
            ++$ExpectedLineCount;
            s/^[0-9]*\|//;
            push @ExpectedContent, $_;
        }
        else {last;}
    }
    close FILE;
    $ExpectedContent = join "", sort @ExpectedContent;
    if ( $ExpectedLineCount == 0 )
    {
        LogMessage "Could not retrieve expected lines from file CumulativeInput.txt in $ROOT/$DataType.", SYSERROR;
        LogMessage "Ending: <$TestName/$DataType> <$ErrorStrings{SYSERROR}>", NO_TIMESTAMP;
        next;
    }

    foreach my $File (@DataFiles)
    {
        if ( system("${STREAMING}/bin/gdat2ascii $File > Output.txt") )
        {
            ExitWithError "Could not run gdat2ascii for $File.";
        }

        open FILE, "Output.txt" or Die "Could not open Output.txt for read.";
        my $LineCount = 0;
        my ($FirstTimeStamp, $CurrentTimeStamp, $OutputContent, @OutputContent);
        while (<FILE>)
        {
            if ( $LineCount++ == 0 )
            { 
                ($FirstTimeStamp) = $_ =~ /^([0-9]+)\|/;
                $CurrentTimeStamp = $FirstTimeStamp;
            }
            else
            {
                ($CurrentTimeStamp) = $_ =~ /^([0-9]+)\|/;
            }
            if ( $CurrentTimeStamp ne $FirstTimeStamp ) { last; }
            s/^[0-9]*\|//;
            push @OutputContent, $_;
        }
        close FILE;
        if ( $LineCount == 0 ) {next;}
        ++$DiffChecked;
        $OutputContent = join "", sort @OutputContent;
        if ( $OutputContent ne $ExpectedContent )
        {
            ++$Exceptions;
            LogMessage "Exceptions found for type $DataType.", FAILURE;
            LogMessage "Expected output was:", NO_TIMESTAMP;
            LogMessage $ExpectedContent, NO_TIMESTAMP;
            LogMessage "Output obtained is:", NO_TIMESTAMP;
            LogMessage $OutputContent, NO_TIMESTAMP;
        }
        else
        {
            LogMessage "No differences found for $DataType.";
            LogMessage "Ending: <$TestName/$DataType> <$ErrorStrings{SUCCESS}>", NO_TIMESTAMP;
        }

        last;
    }
    if ( $DiffChecked == 0 )
    {
        LogMessage "Can not identify valid text file expected from gsgdatprint for type $DataType.", FAILURE;
    }
}


if ( ! $Exceptions and $ExitCode == SUCCESS )
{
    LogMessage "All $TestName comparisons succeeded.";
}
LogMessage "Ending: <$TestName> <$ErrorStrings{$ExitCode}>\n", NO_TIMESTAMP;
LogMessage("----------------------------------------------------------------------------------------------", NO_TIMESTAMP);
exit $ExitCode;


sub GetProcess
{
    my @PROCESSES = ();
    if  ( @_ > 1 or !defined $_[0] or $_[0] eq "" )
    {
        print STDERR "Invalid parameters @_\n";
        return undef;
    }
    my $JobToKill = $_[0];
    open PS, "ps -$GID|" or Die "Could not open ps command: $!";
    while ( my $PROCESS=<PS> )
    {
        if ( $PROCESS =~ /\b${JobToKill}\b/ )
        {
            $PROCESS =~ s/^ *//;
            my @ProcessDetails = split /  */, $PROCESS;
            if ( $ProcessDetails[0] != $$ ) { push @PROCESSES, $ProcessDetails[0]; }
        }
    }
    close PS;
    return @PROCESSES;
}

sub KillAll
{
	$ret = system("./stopit");
	if($ret != 0){
		print "Warning, could not execute ./stopit, return code is $ret\n";
	}

    my @PROCESSES = ();
    foreach my $PROCESS qw( gshub.py rts hfta_0 hfta_1 hfta_2 gsprintconsole gen_feed gsgdatprint gendata.pl)
    {
        push @PROCESSES, GetProcess $PROCESS
    }
    if ( @PROCESSES ){print "kill -KILL @PROCESSES\n";}
    if ( @PROCESSES and kill( 'KILL', @PROCESSES ) != @PROCESSES )
    {
        LogMessage "Could not kill processes @PROCESSES.", SYSERROR;
        return SYSERROR;
    }
    return 0;
}

sub Ps
{
    my @ProcessList = qw( gshub.py rts hfta_0 hfta_1 hfta_2 gsprintconsole gen_feed gsgdatprint gendata.pl);
    my $QueriedProcess;
    if  ( @_ > 1 or (@_ == 1 && (!defined $_[0] or $_[0] eq "")) )
    {
        print STDERR "Invalid parameters @_\n";
        exit SYSERROR;
    }
    elsif ( @_ == 1 )
    {
        $QueriedProcess = shift;
        if ( !exists {map{ $_ => 1 } @ProcessList}->{$QueriedProcess} )
        {
            print STDERR "The parameter $QueriedProcess is not one of the expected process names: @ProcessList.";
            exit SYSERROR;
        }
    }

    open PS, "ps -$GID|" or Die "Could not open ps command: $!";
    my $Count = 0;
    while ( my $PROCESS=<PS> )
    {
        foreach my $TargetProcess (@ProcessList)
        {
            if ( $PROCESS =~ /\b${TargetProcess}\b/ )
            {
                if ( defined $QueriedProcess and $QueriedProcess eq $TargetProcess )
                {
                    ++$Count;
                    last;
                }
                elsif ( defined $QueriedProcess )
                {
                    next;
                }
                ++$Count;
                print $PROCESS;
                last;
            }
        }
    }
    close PS;
    return $Count;
}


sub ExitWithError
{
    if  ( @_ > 2 or !defined $_[0] or $_[0] eq "" )
    {
        print STDERR "Invalid parameters @_\n";
        exit SYSERROR;
    }

    my $ExitCode = FAILURE;
    if ( @_ == 2 and $_[1] != FAILURE and $_[1] != SYSERROR )
    {
        print STDERR "Invalid parameters @_\n";
        exit SYSERROR;
    }
    elsif ( @_ == 2 )
    {
        $ExitCode = $_[1];
    }

    LogMessage $_[0], $ExitCode;
    KillAll;
    exit $ExitCode;
}

sub Die
{
    if  ( @_ > 1 or !defined $_[0] or $_[0] eq "" )
    {
        print STDERR "Invalid parameters @_\n";
        exit SYSERROR;
    }
    my $PWD = cwd();
    my ($PARENT_DIR, $CURRENT_DIR) = $PWD =~ /^(.*)\/([^\/]+)$/;
    ($PARENT_DIR) = $PARENT_DIR =~ /^.*\/([^\/]+)$/;
    LogMessage $_[0], SYSERROR;
    KillAll;
    if ( $PARENT_DIR eq "$TestName" or $CURRENT_DIR eq "$TestName" )
    {
        my $DIR_DETAILS = "$TestName";
        if ( $CURRENT_DIR ne "$TestName" ) { $DIR_DETAILS = "$DIR_DETAILS/$CURRENT_DIR"; }
        LogMessage "Ending: <$DIR_DETAILS> <$ErrorStrings{SYSERROR}>", NO_TIMESTAMP;
    }
    exit SYSERROR;
}

sub LogMessage
{
    my $TimeStampFlag = TIMESTAMP;
    if  ( @_ > 3 or !defined $_[0] or $_[0] eq "" )
    {
        print STDERR "Invalid parameters passed to LogMessage()\n";
        exit SYSERROR;
    }
    my $Message = shift;
    chomp $Message;
    my $CurrentErrorCode = SUCCESS;

    if ( @_ >= 1 )
    {
        if ( $_[0] != SUCCESS  and $_[0] != FAILURE and $_[0] != SYSERROR and $_[0] != NO_TIMESTAMP )
        {
            print STDERR "Invalid parameters passed to LogMessage\n";
            exit SYSERROR;
        }
        if ( $_[0] == NO_TIMESTAMP )
        {
            $TimeStampFlag = shift;
        }
        else
        {
            $CurrentErrorCode = shift;
        }
    }

    if ( @_ == 1 and (($_[0] != NO_TIMESTAMP and $_[0] != TIMESTAMP) or defined $TimeStampFlag) )
    {
        print STDERR "Invalid parameters passed to LogMessage\n";
        exit SYSERROR;
    }
    elsif ( @_ == 1 )
    {
        $TimeStampFlag = shift;
    }


    $Stream = ($CurrentErrorCode == SUCCESS) ? STDOUT : STDERR;
    print $Stream $Message . "\n";
    if ( $TimeStampFlag != NO_TIMESTAMP ) 
    {
        my ($Second,$Minute,$Hour,$DayOfMonth,$Month,$Year) = localtime();
        $Year += 1900;
        $Month += 1;
        $Message = sprintf("$Months{$Month} %02d, %04d, %02d:%02d:%02d $Message",
                                  $DayOfMonth, $Year, $Hour, $Minute, $Second);
    }
    open FILE, ">>$LogFile" or Die "Could not open the log file $LogFile for write.\n";
    print FILE $Message . "\n";
    close FILE;
    Die "Could not chmod on $LogFile." unless chmod(0777, "$LogFile") == 1;
    if ( $CurrentErrorCode != SUCCESS )
    {
        $ExitCode = $CurrentErrorCode;
    }
}
