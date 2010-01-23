#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use Progress::Stack;
use List::Util qw(sum reduce);

plan tests => 12;

# testrenderer to check values
my @resultpercent = ();
my $lastmessage = "";
sub testrenderer($$) {
	my $value = shift;
	my $message = shift;
	if($message eq $lastmessage && scalar @resultpercent) {
		push @resultpercent, [$value];
	} else {
		push @resultpercent, [$value, $message];
		$lastmessage = $message;
	}
}

# First test testsuite
@resultpercent = ();
testrenderer(0, "test");
testrenderer(50, "test");
testrenderer(100, "test2");
is_deeply(\@resultpercent, [[0,"test"],[50],[100,"test2"]], "testsuite test");

# simple
@resultpercent = ();
init_progress(message => "Simple", renderer => \&testrenderer, forceupdatevalue => 0);
update_progress 20;
update_progress 60;
update_progress 100;
is_deeply(\@resultpercent,[[0,"Simple"],[20],[60],[100]], "simple");

# loop
@resultpercent = ();
init_progress(message => "loop", renderer => \&testrenderer, forceupdatevalue => 0);
for_progress {} 1..5;
is_deeply(\@resultpercent,[[0,"loop"],[20],[40],[60],[80],[100]], "loop");

# check whether reduce_progress works the same way as reduce
init_progress(minupdatetime => 1, renderer => sub {}, forceupdatevalue => 2, message => "Calculating sum of cubes");
is ((reduce_progress {$a + $b*$b*$b} 1..100000),(reduce {$a + $b*$b*$b} 1..100000), "reduce");

# sub_progress
@resultpercent = ();
init_progress(message => "Subprogress", renderer => \&testrenderer, forceupdatevalue => 0);
sub A {
	my $param = shift;
	update_progress 0, "Processing A($param)";
	update_progress 25;
	update_progress 50;
}

sub B($) {
	my $param = shift;
	update_progress 0, "Processing B($param)";
	update_progress 10;
	sub_progress {A($param)} 50;
	update_progress 60;
	update_progress 80;
}

sub_progress {A(1)} 25;
sub_progress {A(2)} 50;
sub_progress {B(3)} 100;
is_deeply(\@resultpercent,[[0,"Subprogress"],[0,"Processing A(1)"],[6.25],[12.5],[25],[25,"Processing A(2)"],[31.25],[37.5],[50],
	[50,"Processing B(3)"],[55],[55,"Processing A(3)"],[60],[65],[75],[80,"Processing B(3)"],[90],[100]], "subprogress");

# nested loops & using next
@resultpercent = ();
init_progress(renderer => \&testrenderer, forceupdatevalue => 0);
sub_progress {for_progress {} 1..10} 50;
my $i=0;
sub_progress {
	for_progress {
		for_progress {
			no warnings;
			$i++;
			next if($i%2);
		} 1..5;
	} 1..10;
} 100;
is_deeply(\@resultpercent,[[0,""],(map {[$_*5]} 1..10), (map {[$_]} 51..100), [100], [100]], "nested loops & using next");
is($i,50,"nested loops & using next -- check number of iterations");

# map_progress
@resultpercent = ();
init_progress(renderer => \&testrenderer, forceupdatevalue => 0);
my @lengths = sub_progress { map_progress {
	update_progress(0,$_);
	length($_);
} qw(Banana Apple Pear Grapes) } 80;
is_deeply(\@resultpercent, [[0,""],[0,"Banana"],[20],[20,"Apple"],[40],[40,"Pear"],[60],[60,"Grapes"],[80]], "map_progress");
is_deeply(\@lengths, [6,5,4,6], "map_progress -- result check");

# threads
use Config;

SKIP: {
	skip "Threads not supported -- skipping threads tests",2 unless $Config{useithreads};
	require threads;
	use Time::HiRes;

	@resultpercent = ();
	threads->new(sub {
		init_progress(renderer => \&testrenderer, forceupdatevalue => 0);
		Time::HiRes::sleep 0.5;
		for_progress {sleep 1} 1..2;
		is_deeply(\@resultpercent, [[0,""],[50],[100]],"second thread");
	});
	init_progress(renderer => \&testrenderer, forceupdatevalue => 0);
	for_progress {sleep 1} 1..5;
	is_deeply(\@resultpercent, [[0,""],[20],[40],[60],[80],[100]],"main thread");
}

# count change
@resultpercent = ();
init_progress(renderer => \&testrenderer, forceupdatevalue => 0, count => 4);
for_progress {
	update_progress(1);
	update_progress(2);
	update_progress(3);
} 1,2;
is_deeply(\@resultpercent, [[0,""],[12.5],[25],[37.5],[50],[62.5],[75],[87.5],[100]],"count change");
