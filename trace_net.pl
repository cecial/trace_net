#!/usr/bin/perl -w
use Data::Dumper;
use Getopt::Long;
use strict;

usage() if (@ARGV< 8);

our ($cir,$top_cell,$path,$sub,$net,$direction)=();
our @path_down=();

GetOptions('cir=s'       => \$cir,
           'top=s'       => \$top_cell,
           'path=s'      => \$path,
           'sub=s'       => \$sub,
           'net=s'       => \$net,
           'direction=s' => \$direction,
);
($top_cell,$path,$sub,$net,$direction)=(lc($top_cell),lc($path),lc($sub),lc($net),lc($direction));

### check param
no strict 'refs';
for (qw(cir top_cell net direction)) {
    if ($$_ eq "") {
        print "\nERROR: $_ is not specified\n\n";
        usage();
    }
}
use strict 'refs';

my $sub_of_search_down_flag=0;
if ($direction eq "down") {
    if ($sub ne "") {
        print "INFO: sub:$sub is specified, path:$path will not be used.\n";
        $sub_of_search_down_flag=1;
    }
} elsif ( $direction eq "up" || $direction eq "all") {
    if ($sub ne "") {
        print "INFO: sub:$sub will not be used when direction is up or all.\n";
        usage();
    }
} else {
    print "\nERROR: direction should be one of [down|up|all]\n\n";
    usage();
}
###

### process with netlist and create info hash of netlist
my $cir_no_plus=remove_plus($cir);
my $cir_no_param=remove_param($cir_no_plus);
my $cir_info=create_cir_info($cir_no_param);
###

if ($direction eq "down") {
    if ($sub_of_search_down_flag == 1) {
        print "Search down of net:[$net] in sub:[$sub]\n";
        search_down($net,$sub,$cir_info);
    } else {
        my $sub=name_of_xinst($path,$cir_info);
        print "Search down of net:[$net] in path:[$path]($sub)\n";
        search_down($net,$sub,$cir_info);
    }
} elsif ($direction eq "up") {
    my $sub=name_of_xinst($path,$cir_info);
    print "Search up of net:[$net] in path:[$path]($sub)\n"; 
    search_up($net,$path,$cir_info);
} else { 
    ### direction eq "all"

    ### Search up first
    my $sub=name_of_xinst($path,$cir_info);
    print "Search up of net:[$net] in path:[$path]($sub)\n"; 
    my ($up_sub,$up_net,@path)=search_up($net,$path,$cir_info);
    print "\n";

    ## Search down
    my $path="";
    my $f=0;
    foreach my $p (@path) {
        $path .= ".$p" if($f>0);
        $path .= "$p" if($f==0);
        $f++;
        my $sub=name_of_xinst($path,$cir_info);
        push @path_down, sprintf "%-50s%-20s\n","    ->$p","($sub)";
    }
    
    print "Search down of net:[$up_net] in sub:[$up_sub]\n";
    search_down($up_net,$up_sub,$cir_info);
}

unlink "$cir_no_plus","$cir_no_param";
    
################################################################################
sub remove_plus {
    my $org_cir=shift;
    my $new_cir="$org_cir.no_plus";

    open (FI,"$org_cir") || die "$org_cir, $!\n";
    open (FO,">$new_cir") || die "$new_cir, $!\n";
    
    while(my $line=<FI>){
        #next if ($line=~/^\s*[\*\$]/ || $line=~/^\s*(\.param|\.option)/i || $line=~/^\s*$/);
        chomp($line);

        if ($line=~s/\s*\+/ /) {
            ### if $line start with "+", then print this line at the end of last line;
            print FO "$line";
        } else {
            ### if $line don't start with "+", then print this line at a new line;
            print FO "\n$line";
        }
    }
    print FO "\n";

    close FI;
    close FO;
    
    return $new_cir;
}

sub remove_param {
    my $org_cir=shift;
    my $new_cir="$org_cir.no_param";

    open (FI,"$org_cir") || die "$org_cir, $!\n";
    open (FO,">$new_cir") || die "$new_cir, $!\n";
    
    while(my $line=<FI>){
        next if ($line=~/^\s*[\*\$]/ || $line=~/^\s*(\.param|\.option)/i || $line=~/^\s*$/);
        chomp($line);

        ### low case netlist
        $line=lc($line);

        ### in case there is "a = b"
        $line=~s/\s*=\s*/=/g;

        ### remove "param=value" in netlist
        $line=~s/\S*=\S*//g;

        ### remove head and end space
        $line=~s/^\s*|\s*$//;

        print FO $line, "\n";
    }

    close FI;
    close FO;

    return $new_cir;
}

sub create_cir_info {
    my $cir=shift;

    my %cir_info=();

    my $is_in_subckt=0;
    my $subckt="";

    open (FI,"$cir") || die "$cir, $!\n";
    while(my $line=<FI>){
        if ($line=~/^\.subckt/i) {
            (undef,$subckt,my @pin)=split(/\s+/,$line);

            ### create subckt info
            $cir_info{$subckt}{pin}=\@pin;
            $cir_info{$subckt}{net}=[];
            $cir_info{$subckt}{xinst}=[];
            $cir_info{$subckt}{dev}=[];
            
            $is_in_subckt=1;
            next;
        } 

        if ($is_in_subckt==1) {
            if ($line=~/^x/i) {
                my @tmp=split(/\s+/,$line);
                my $x=shift(@tmp);
                my $x_sub=pop(@tmp);
                push @{$cir_info{$subckt}{xinst}},$x;
                $cir_info{$subckt}{$x}{name}=$x_sub;
                $cir_info{$subckt}{$x}{net}=[@tmp];

                ### collect net in subckt
                foreach (@tmp) {
                    push @{$cir_info{$subckt}{net}},$_ unless (is_exist_in_array($_,$cir_info{$subckt}{pin}) || is_exist_in_array($_,$cir_info{$subckt}{net}));
                }

                next;

            } elsif ($line=~/^[mrcd]/i) {
                my @tmp=();
                if ($line=~/^m/i) {
                    @tmp=(split(/\s+/,$line))[0..4]; # only need name and d/g/s/b
                } else {
                    @tmp=(split(/\s+/,$line))[0..2]; # only need name and node1/node2
                }
                my $x=shift(@tmp);
                push @{$cir_info{$subckt}{dev}},$x;
                $cir_info{$subckt}{$x}{net}=[@tmp];

                ### collect net in subckt
                foreach (@tmp) {
                    push @{$cir_info{$subckt}{net}},$_ unless (is_exist_in_array($_,$cir_info{$subckt}{pin}) || is_exist_in_array($_,$cir_info{$subckt}{net}));
                }

                next;

            } elsif ($line=~/^\.ends/i) {
                $is_in_subckt=0;
            } else {
                print "unkown format line: $. $line\n";
            }
        }

    }

    close FI;

    return \%cir_info;

}

sub search_down {
    my ($pin_or_net,$subckt,$cir_info)=@_;

    my $float=1;

    unless (defined($cir_info->{$subckt})) {
        die "$subckt does not exist in the netlist\n";
    }

    ### check pin_or_net exist in subckt
    unless (is_exist_in_array($pin_or_net,$cir_info->{$subckt}{pin}) || is_exist_in_array($pin_or_net,$cir_info->{$subckt}{net})) {
        print "[$pin_or_net] does not exist in $subckt\n";
        return;
    }

    ### check hier down
    foreach my $x (@{$cir_info->{$subckt}{xinst}}) {
        if (is_exist_in_array($pin_or_net,$cir_info->{$subckt}{$x}{net})) {
            $float=0; #pin_or_net is not floating

            my @all_index=all_index_of_element_in_array($pin_or_net,$cir_info->{$subckt}{$x}{net});
            
            foreach my $index (@all_index) {
                my $x_sub=$cir_info->{$subckt}{$x}{name};
                my $pin_of_x_sub=$cir_info->{$x_sub}{pin}[$index];

                ### check pin number and net number equal
                if ($#{$cir_info->{$subckt}{$x}{net}} != $#{$cir_info->{$x_sub}{pin}}) {
                    print "net number != pin number in ($subckt->$x <=> $x_sub)\n";
                    return;
                }
    
                push @path_down,sprintf "%-50s%-20s\n","    ->$x","($x_sub,$pin_of_x_sub)";
    
                search_down($pin_of_x_sub,$x_sub,$cir_info);
                pop @path_down;
            }
        }
    }

    ### finish search
    foreach my $x (@{$cir_info->{$subckt}{dev}}) {
        if (is_exist_in_array($pin_or_net,$cir_info->{$subckt}{$x}{net})) {
            $float=0;

            print $_ foreach (@path_down);
            printf "%-50s","    ->$x";
            print "@{$cir_info->{$subckt}{$x}{net}}\n\n";

            return;
        }
    }

    ### is a floating pin
    if ($float == 1) {
        print $_ foreach (@path_down);
        print "    ->[$pin_or_net] is floating in $subckt\n\n";
        return;
    }
}

sub search_up {
    my ($pin_or_net,$path,$cir_info)=@_;
    
    my @path=split(/\./,$path);
    
    my $sub=name_of_xinst($path,$cir_info);

    if (is_exist_in_array($pin_or_net,$cir_info->{$sub}{pin})) {
        if ($sub eq $top_cell) {
            return ($sub,$pin_or_net);
        } else {
            my $index=first_index_of_element_in_array($pin_or_net,$cir_info->{$sub}{pin});

            ### remove last xinst,build new path
            my $x=pop(@path);
            my $new_path=join(".",@path);
            my $new_sub=name_of_xinst($new_path,$cir_info);
            my $new_pin_or_net=$cir_info->{$new_sub}{$x}{net}[$index];
            printf "%-50s%-20s\n","    ->$new_path","($new_sub,$new_pin_or_net)";
            #printf "%-50s%-20s\n","    ->$new_path.$new_pin_or_net","($new_sub)";

            search_up($new_pin_or_net,$new_path,$cir_info);
        }
    } elsif (is_exist_in_array($pin_or_net,$cir_info->{$sub}{net})) {
        return ($sub,$pin_or_net,@path);
    } else {
        print "[$path.$pin_or_net] does not exist!\n";
    }
}

sub is_exist_in_array {
    my ($ele,$array_ref)=@_;

    foreach (@$array_ref) {
        return 1 if ($ele eq $_);
    }

    return 0;
}
    

sub first_index_of_element_in_array {
    my ($ele,$array_ref)=@_;

    for (0..$#$array_ref) {
        return $_ if ($ele eq $array_ref->[$_]);
    }

    return "not exist in array";
}

sub all_index_of_element_in_array {
    my ($ele,$array_ref)=@_;
    my @all_index=();

    for (0..$#$array_ref) {
        push @all_index, $_ if ($ele eq $array_ref->[$_]);
    }

    return @all_index;
}

sub name_of_xinst {
    my ($path,$cir_info)=@_;

    my @path=split(/\./,$path);
    
    my $sub=$top_cell;

    foreach my $p (@path) {
        if (defined($cir_info->{$sub}{$p})) {
            $sub=$cir_info->{$sub}{$p}{name};
        } else {
            die "[$p] in $sub does not exist!\n";
        }
    }

    return $sub;
}

sub usage {
    chomp(my $name=`basename $0`);
    print <<EOF;

    Usage:
      $name 
            -cir <netlist> 
            -top <topcell name> 
            [-path <hierarchical path> | -sub <subckt name>] 
            -net <net or pin> 
            -direction <down|up|all>
    ---
      -cir      : netlist file name, topcell should not be commented.
      -top      : topcell name in netlist.
      -path     : path of net, like xtop.xgbank.xgio.xio1, seperator should be ".", 
                  and path should be from topcell.
                : if the "net" is at top level, then this option should not be used.
      -sub      : subckt name in which the net locates. only available when direction option is down
      -net      : the net name which will be traced. 
                  net should be net or pin in the subckt which path point to or specified by sub option.
      -direction: can be one the three option:
                  down: search the net down to bottom level.
                  up  : search the net up to top level.
                  all : search the net up to top level first, 
                        then search from top level to bottom level.
    ---
      This script is used to trace net in netlist, to make the hierarchical connetion clear.
    ---

EOF
    exit;
}

