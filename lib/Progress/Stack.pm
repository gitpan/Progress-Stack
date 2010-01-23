package Progress::Stack;

require 5.008;

$VERSION    = "1.00";

use strict;
use warnings;

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT	= qw(
	&init_progress &update_progress &sub_progress &for_progress &file_progress
	&map_progress &reduce_progress &push_progress &pop_progress
);

use Time::HiRes;

use constant {
	PSTART => 0,
	PEND => 1,
	PMESSAGE => 2,
	PFACTOR => 3,
};

sub new($;%)
{
	my $module = shift;
	my %param = @_;
	my $self = {
		progressstack => [[0,100,"",1]],
		starttime => Time::HiRes::time,
		lastprogresstime => Time::HiRes::time,
		lastprogress => 0,
		actuallastprogress => 0,
		count => 100,
		minupdatetime => 0.1,	# seconds
		minupdatevalue => 0.1,	# percents
		forceupdatevalue => 1,	# percents
		renderer => \&defRenderer,
	};
	foreach(qw(count minupdatetime minupdatevalue forceupdatevalue)) {
		if(defined($param{$_})) {
			if(ref($param{$_}) ne "") {
				die "'$_' must be scalar";
			}
			$self->{$_} = $param{$_}*1.;
		}
	}
	$self->{progressstack}[0][PEND] = $self->{count};
	$self->{nextminupdate} = $self->{minupdatevalue} + $self->{lastprogress};
	$self->{nextforceupdate} = $self->{forceupdatevalue} + $self->{lastprogress};
	$self->{nexttimeupdate} = $self->{minupdatetime} + $self->{lastprogresstime};
	if(defined($param{message})) {
		$self->{progressstack}[0][PMESSAGE] = $param{message};
	}
	if(defined($param{renderer})) {
		if(ref($param{renderer}) ne "CODE") {
			die "'renderer' must be 'CODE'";
		}
		$self->{renderer} = $param{renderer};
	}
	bless $self, $module;
	&{$self->{renderer}}(0,$self->{progressstack}[0][PMESSAGE],$self);
	return $self;
}

sub defRenderer($;$$)
{
	my $val = shift;
	my $message = shift;
	my $progress=sprintf("%5.1f", $val);
	local $|=1;
	print "\r".(" " x 70)."\r[".("#" x int($progress/5)).(" " x (20-int($progress/5)))."] ${progress}% ${message}";
}

sub update($;$$)
{
	my ($self, $progress, $action) = @_;
	my ($s, $e, $lastaction, $curfactor) = @{$self->{progressstack}[-1]};
	$progress = $self->{count} if !defined($progress);
	$action=$lastaction if !defined($action);
	$progress=$progress*$curfactor+$s;
	$self->{actuallastprogress}=$progress;
	# Suppress too often updates
	# Time check should be the last as it's the slowest
	return if($action eq $lastaction && $progress<$self->{count} && 
		($progress<$self->{nextminupdate} ||
		($progress<$self->{nextforceupdate} &&
		Time::HiRes::time<$self->{nexttimeupdate}))
	);
	$self->{progressstack}[-1][PMESSAGE]=$action;
	$self->{lastprogress}=$progress;
	$self->{lastprogresstime}=Time::HiRes::time;
	$self->{nextminupdate} = $self->{minupdatevalue} + $self->{lastprogress};
	$self->{nextforceupdate} = $self->{forceupdatevalue} + $self->{lastprogress};
	$self->{nexttimeupdate} = $self->{minupdatetime} + $self->{lastprogresstime};
	&{$self->{renderer}}($progress/$self->{count}*100,$action,$self);
}

sub push($$$)
{
	my ($self, $_s, $_e) = @_;
	my ($s, $e, $lastaction, $curfactor) = @{$self->{progressstack}[-1]};
	$_s=$_s*$curfactor+$s;
	$_e=$_e*$curfactor+$s;
	push @{$self->{progressstack}}, [$_s, $_e, $lastaction, $_e<=$_s?0:($_e-$_s)/$self->{count}];
}

sub pop($)
{
	my $self = shift;
	if(scalar @{$self->{progressstack}} == 1) {
		die "Attempt to pop from empty progress stack!";
		return;
	}
	pop @{$self->{progressstack}};
}

sub sub($&$) {
	my ($self, $code, $end) = @_;
	my $start = $self->{actuallastprogress};
	my ($s, $e) = @{$self->{progressstack}[-1]};
	$start = $e<=$s?0:($start-$s)*$self->{count}/($e-$s);
	$self->push($start, $end);
	my @retval = &{$code}();
	$self->update();
	$self->pop();
	return @retval;
}

sub for($&@) {
	my $self = shift;
	my $code = shift;
	my $nelem = scalar @_;
	return if !$nelem;
	local $_;
	my $i=0;
	my $stepsize = $self->{count}/$nelem*$self->{progressstack}[-1][PFACTOR];
	my $curs = $self->{progressstack}[-1][PSTART];
	$self->push(0, $self->{count}/$nelem);
	my $stacktop = $self->{progressstack}[-1];
	foreach(@_) {
		if($i++) {
			# Time check should be the last as it's the slowest
			$self->update() if $stacktop->[PEND]>=$self->{nextminupdate} &&
				($stacktop->[PEND]>=$self->{nextforceupdate} ||
				Time::HiRes::time>=$self->{nexttimeupdate});
			$stacktop->[PSTART] = $stacktop->[PEND];
			$stacktop->[PEND] = $i*$stepsize+$curs;
		}
		# Code must be the last operator in the cycle,
		# because it's allowed to do next or last from there
		&{$code}();
	}
	$self->update() if($i);
	$self->pop();
}

sub map($&@) {
	my $self = shift;
	my $code = shift;
	my $nelem = scalar @_;
	return {} if !$nelem;
	local $_;
	my $i=0;
	my @res;
	my $stepsize = $self->{count}/$nelem*$self->{progressstack}[-1][PFACTOR];
	my $curs = $self->{progressstack}[-1][PSTART];
	$self->push(0, $self->{count}/$nelem);
	my $stacktop = $self->{progressstack}[-1];
	foreach(@_) {
		if($i++) {
			# Time check should be the last as it's the slowest
			$self->update() if $stacktop->[PEND]>=$self->{nextminupdate} &&
				($stacktop->[PEND]>=$self->{nextforceupdate} ||
				Time::HiRes::time>=$self->{nexttimeupdate});
			$stacktop->[PSTART] = $stacktop->[PEND];
			$stacktop->[PEND] = $i*$stepsize+$curs;
		}
		# Code must be the last operator in the cycle,
		# because it's allowed to do next or last from there
		CORE::push @res, &{$code}();
	}
	$self->update() if($i);
	$self->pop();
	return @res;
}

sub reduce($&@) {
	my $self = shift;
	my $code = shift;
	local $_;
	my $i=0;
	my $caller = caller;
	$caller = caller(1) if($caller eq "Progress::Stack");
	no strict "refs";
	local(*{$caller."::a"}) = \my $a;
	local(*{$caller."::b"}) = \my $b;
	use strict "refs";

	$a = shift;
	my $nelem = scalar @_;
	return $a if !$nelem;
	my $stepsize = $self->{count}/$nelem*$self->{progressstack}[-1][PFACTOR];
	my $curs = $self->{progressstack}[-1][PSTART];
	$self->push(0, $self->{count}/$nelem);
	my $stacktop = $self->{progressstack}[-1];
	foreach (@_) {
		if($i++) {
			# Time check should be the last as it's the slowest
			$self->update() if $stacktop->[PEND]>=$self->{nextminupdate} &&
				($stacktop->[PEND]>=$self->{nextforceupdate} ||
				Time::HiRes::time>=$self->{nexttimeupdate});
			$stacktop->[PSTART] = $stacktop->[PEND];
			$stacktop->[PEND] = $i*$stepsize+$curs;
		}
		$b = $_;
		$a = &{$code}();
	}
	$self->update() if($i);
	$self->pop();
	return $a;
}

sub file($&*) {
	my $self = shift;
	my $code = shift;
	my $fh = shift;
	my $curpos = tell $fh;
	my $flength = (stat($fh))[7]||1;
	local $_;
	my $i=0;
	my $lastpos = $curpos;
	while(<$fh>) {
		if($i) {
			$self->update();
			$self->pop();
		}
		$curpos = tell $fh;
		$self->push($lastpos*$self->{count}/$flength, $curpos*$self->{count}/$flength);
		$lastpos = $curpos;
		$i=1;
		# Code must be the last operator in the cycle,
		# because it's allowed to do next or last from there		
		&{$code}();		
	}
	if($i) {
		$self->pop();
		$self->update();
	}
}

my $curprogress;

sub init_progress(%) {
	$curprogress = new Progress::Stack(@_);
}

sub update_progress(;$$) {
	$curprogress->update(@_);
}

sub sub_progress(&$) {
	return $curprogress->sub(@_);
}

sub for_progress(&@) {
	$curprogress->for(@_);
}

sub map_progress(&@) {
	return $curprogress->map(@_);
}

sub reduce_progress(&@) {
	return $curprogress->reduce(@_);
}

sub file_progress(&*) {
	return $curprogress->file(@_);
}

sub push_progress($$) {
	$curprogress->push(@_);
}

sub pop_progress() {
	$curprogress->pop();
}

1;

=head1 NAME

Progress::Stack - Progress bar implementation with stack support and useful loop wrappers

=head1 SYNOPSIS

    use Progress::Stack;

    init_progress;
    sleep(1);
    update_progress 20;
    sleep(2);
    update_progress 60;
    sleep(2);
    update_progress 100;
    print "\n";

    init_progress(message => "Calculating");
    my $sum = 0;
    for_progress {
        $sum+=$_;
        sleep(1);
    } 0..10;
    print "\nSum = $sum\n";

=head1 DESCRIPTION

C<Progress::Stack> creates a convenient framework for adding progress bars to long processes.
Sometimes you have long process which consists of several subprocesses, some of which have
cycles (including nested ones), some called several times and so on. If you want to display
continuous progress bar from 0% to 100% for such complex process, you will have bad times
calculating current percentage for each subprocess. C<Progress::Stack> does much of dirty work
for you.

Note that C<Progress::Stack> provides only simple console renderer of current progress.
If you want to use it in some GUI application, you should write your own renderer and pass it
to C<init_progress> (see below).

There are two interfaces provided: one object-oriented, the other don't. Non-OO interface actually
creates single object and delegates all calls to it. Practically using non-OO interface is enough in
many cases, especially taking into account that different threads will have independent progress
bars, but for some windowed applications several progress bars might be necessary.

=head2 Non-OO interface

=over 4

=item init_progress %parameters

Initializes progress bar and updates it to 0%. Parameters (all optional) include:

=over 4

=item message

Default message describing the action performed. This will be passed to
renderer and displayed to the user. Can be overridden later by C<update_progress> calls.

Default value: empty string.

=item count

Maximum value for your progress bar. This takes effect when you call C<update_progress> or C<sub_progress>.
Example:

    init_progress(count => 2);
    sleep(1);
    update_progress(1);  # means half of process is done
    sleep(2);
    update_progress(2);  # means whole process is done

Default value: 100.

Actually it's better not to use this parameter at all always scaling your progress bar from 0 to 100.

=item renderer

Subroutine to be called when progress bar should be updated. Note that calling C<update_progress>
doesn't mean this C<renderer> will be called for sure. C<update_progress> may suppress calls to the
C<renderer> in order not to update progress bar too fast.

C<renderer> receives three parameters: C<$value>, C<$message> and C<$progress>. C<$value> is float
value between 0 and 100 (regardless of C<count> parameter) which represents current progress.
C<$message> is supplementary message describing current action. C<$progress> is internal progress
bar object, which you can use to access some advanced parameters. For example if you want to
calculate estimated time, you can use $progress->{starttime} to get time when the process started.

Default renderer provides simple console output like this:

    [#####               ] 25.0% Message

=item minupdatetime

Time in seconds during which updates of progress bar (C<renderer> calls) are disabled unless message
changed, progress bar changed more than C<forceupdatevalue> (see below) or reached 100%.

Default value is 0.1.

=item minupdatevalue

Progress bar update will be disabled if difference between current and previous value less than this
parameter unless message changed or progress bar reached 100%.

Default value is 0.1.

=item forceupdatevalue

Progress bar update will be enabled if difference between current and previous value exceeds this
parameter even if C<minupdatetime> haven't passed yet.

Default value is 1.

=back

=item update_progress VALUE, MESSAGE

=item update_progress VALUE

=item update_progress

Inform progress bar that it should be updated to value C<VALUE> and message should be
changed to C<MESSAGE>. If C<MESSAGE> is omitted, last message on current stack level will be used:

    init_progress;
    update_progress 0, "Outside";
    sleep 1;
    update_progress 20;  # "Outside" message will be used
    sleep 1;
    sub_progress {
        update_progress 0, "Inside";
        sleep 1;
        update_progress 50; # "Inside" message will be used
        sleep 1;
    } 70;
    sleep 1;
    update_progress 80;  # "Outside" message will be used again

If VALUE is omitted, then maximal value will be used (specified by C<count> in C<init_progress>, 100
by default). Progress bar will be updated for sure if it reached 100% or message changed since last
time. Otherwise actual update (call to C<renderer>) may not be performed depending on
C<minupdatetime>, C<minupdatevalue> and C<forceupdatevalue> parameters (see C<init_progress>).

=item sub_progress BLOCK, VALUE

Pushes current progress bar range and message to the stack, shortens range to C<[curvalue, VALUE]>
(where C<curvalue> determined by the latest C<update_progress> call), evaluates block, calls
C<update_progress> and pops current state back. This function lets you defining subprocesses, inside
which you can use whole range [0, 100] in C<update_progress> calls as for top-level process. Example:

    init_progress;
    # This subprocess uses [0, 50] progress bar range
    sub_progress {
        sleep 2;
        # 20% will be displayed, because we're inside subprocess
        update_progress 40;
        sleep 2;
        # 40% will be displayed, because we're inside subprocess
        update_progress 80;
        sleep 1;
        # note that at the end of subprocess update_progress
        # is called automatically, thus 50% will be displayed
    } 50;
    # This subprocess uses [50, 100] progress bar range
    sub_progress {
        sleep 1;
        # 75%
        update_progress 50;
        sleep 1;
        # 100% will be displayed automatically
    } 100;

In general any call of function, which works long enough to update progress by its own, should be
wrapped into C<sub_progress>, because function should not care whether it's top-level process or
part of any subprocess:

    # Pass of some long process
    sub pass() {
        update_progress 0, "Performing pass";
        sleep(1);
        update_progress 50;
        sleep(1);
        update_progress 100; # just for the case it's top-level process
    }
    # Process consisting of two passes:
    init_progress;
    sub_progress {pass} 50; # will display 25%, then 50%
    sub_progress {pass} 100; # will display 75%, then 100%

Of course C<sub_progress> can be unlimitedly nested. Example:

    init_progress;
    sub_progress {
        sub_progress {
            update_progress 0, "First step of first step";
            sleep(1);
            update_progress 50; # 10% displayed
            sleep(1);
        } 40;
        sub_progress {
            update_progress 0, "Last step of first step";
            sleep(1);
            update_progress 50; # 35% displayed
            sleep(1);
        } 100
    } 50;
    sub_progress {
        update_progress 0, "Last step";
        sleep(1);
        update_progress 50; # 75% displayed
        sleep(1);
    } 100;

If C<BLOCK> returns value, it will be returned by C<sub_progress>.

=item for_progress BLOCK, LIST

Evaluates C<BLOCK> for each element from C<LIST>, loading its elements consequently into C<$_>. For
each iteration C<sub_progress> is called reducing the progress bar range to appropriate part assuming
that each iteration takes the same time. At the end of iteration C<update_progress> is called
automatically. You can use C<next> and C<last> as in normal C<for> cycle. Example:

    init_progress;
    for_progress {
        sleep 1;
    } 1..10;

In this example progress bar will display 10%, 20% and so on till 100%.

Inside C<BLOCK> you can call C<update_progress> changing C<VALUE> from 0 to 100, which represents
progress of current iteration:

    init_progress;
    for_progress {
        update_progress(0, "Processing $_");
        sleep 1;
        update_progress(50, "Processing $_");
        sleep 1;
    } qw(Banana Apple Pear Grapes);

You will see the following sequence of progress bar updates:

    [                    ]   0.0% Processing Banana
    [##                  ]  12.5% Processing Banana
    [#####               ]  25.0% Processing Banana
    [#####               ]  25.0% Processing Apple
    [#######             ]  37.5% Processing Apple
    [##########          ]  50.0% Processing Apple
    [##########          ]  50.0% Processing Pear
    [############        ]  62.5% Processing Pear
    [###############     ]  75.0% Processing Pear
    [###############     ]  75.0% Processing Grapes
    [#################   ]  87.5% Processing Grapes
    [####################] 100.0% Processing Grapes

Of course nested loops work fine also:

    init_progress;
    for_progress {
        for_progress {
            sleep 1;
        } 1..$_;
    } 1..5;

Note that this progress bar will become slower to the end as C<for_progress> assumes each iteration
takes the same time, but latter iterations of outer C<for_progress> are obviously slower.

=item map_progress BLOCK, LIST

Similar to C<for_progress> but works like C<map> returning list of processed elements:

    init_progress();
    my @lengths = map_progress {
        sleep(1);
        length($_);
    } qw(Banana Apple Pear Grapes);

=item reduce_progress BLOCK, LIST

Similar to C<for_progress> but works like C<List::Util::reduce> returning accumulated value:

    init_progress(minupdatevalue => 1);
    print "\nSum of cubes from 1 to 1000000 = ".reduce_progress {$a + $b*$b*$b} 1..1000000;

Note that this works much slower than simple C<List::Util::reduce> (about 4-5 times as measured).
Thus use carefully in cases when single iteration is very short. You may consider optimizing the
process decomposing the loop into two nested ones and using progress for outer only like this:

    use List::Util qw(reduce);
    init_progress;
    print "\nSum of cubes from 1 to 1000000 = ".reduce {$a + $b} 
        map_progress {reduce {$a + $b} map {$_*$_*$_} $_*1000-999..$_*1000} 1..1000;

=item file_progress BLOCK, FH

Similar to C<for_progress> but reads text file by given filehandle C<FH> line by line. Progress range
is based on current offset inside the file and file size. Thus filesize should be known for this
filehandle. Example:

    init_progress;
    open(F, "test.txt") || die "$!";
    my $nbytes = 0;
    file_progress {
        $nbytes+=length($_);
        sleep(1);
    } \*F;
    print "\nLength = $nbytes\n";

=item push_progress START, END

Low-level function to put new progress range into stack. Also the last message is saved there.
Generally you shouldn't use it unless you extend capabilities of this module.

=item pop_progress

Low-level function to remove current progress rango from stack, activating previous progress range
and message. It will C<die> if you call it on empty stack. Generally you shouldn't use it unless you
extend capabilities of this module.

=back

=head2 Object-oriented interface

Object-oriented interface is pretty similar to subroutine interface described above. To get the
progress bar object, instead of C<init_progress> you should call C<new Progress::Stack> (parameters
are the same). All methods of this object are the same as functions above, but without suffix
'_progress' in the title (C<update>, C<sub>, C<for>, C<map>, C<reduce>, C<file>, C<push> and C<pop>).
Parameters are the same except that first parameter is the object. Thus, one of above examples
may be rewritten as following:

    my $p = new Progress::Stack;
    $p->for(sub {
        $p->for(sub {
            sleep 1;
        }, 1..$_);
    }, 1..5);

=head1 COPYRIGHT

Copyright (c) 2009-2010 Tagir Valeev <lan@nprog.ru>. All rights reserved.
This program is free software; you can redistribute it and/or
modify it under the same terms as Perl itself.

=cut
