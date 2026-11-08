#!/usr/bin/perl

use strict;
use warnings;

my ($command, $marks_file, $mode) = @ARGV;
die "usage: $0 generate | check <marks> <mode>\n"
	unless defined($command) &&
	($command eq 'generate' || ($command eq 'check' && defined($mode)));

# Use our own PRNG so the cases do not depend on Perl's rand() implementation.
# All intermediate values fit in a signed 32-bit integer. Use the high bits
# when choosing a value, since the low bits of an LCG have a short period.
my $state;
sub random_below {
	my ($limit) = @_;
	$state = ($state * 25173 + 13849) % 65536;
	return int($state * $limit / 65536);
}

sub generate {
	my ($seed) = @_;
	# Keep the minimal tied-date regression alongside the random cases:
	# c1 is the best common ancestor of c1 and merge(c0, c1).
	return ([[], [0], [0, 1]], [1000, 1000, 1000], [[1, 2]])
		unless $seed;

	$state = $seed;
	my $n = 3 + random_below(10);
	my (@parents, @dates, @pairs);
	for my $i (0..$n - 1) {
		my @p;
		if ($i && random_below(5)) {
			push @p, random_below($i);
			if ($i > 1 && random_below(2)) {
				my $other = random_below($i - 1);
				$other++ if $other >= $p[0];
				push @p, $other;
			}
		}
		push @parents, [sort { $a <=> $b } @p];
		push @dates, 1000 * (1 + random_below(4));
	}
	for (1..3) {
		my $a = random_below($n);
		my $b = random_below($n - 1);
		$b++ if $b >= $a;
		push @pairs, [$a, $b];
	}
	return (\@parents, \@dates, \@pairs);
}

# Compute reflexive ancestor sets using only the generated parent lists.
# A common ancestor is best iff no other common ancestor reaches it.
# Neither this oracle nor the generator asks Git to walk the graph.
sub best_common_ancestors {
	my ($parents, $a, $b) = @_;
	my @ancestors;
	for my $i (0..$#$parents) {
		my %seen;
		my @todo = ($i);
		while (@todo) {
			my $c = pop @todo;
			next if $seen{$c}++;
			push @todo, @{$parents->[$c]};
		}
		push @ancestors, \%seen;
	}
	my @common = grep { $ancestors[$a]{$_} && $ancestors[$b]{$_} }
		0..$#$parents;
	return grep {
		my $c = $_;
		!grep { $_ != $c && $ancestors[$_]->{$c} } @common;
	} @common;
}

my %oid;
if ($command eq 'check') {
	open my $marks, '<', $marks_file or die "open $marks_file: $!";
	while (<$marks>) {
		/^:(\d+) ([0-9a-f]+)\n$/ or die "bad mark: $_";
		$oid{$1} = $2;
	}
	close $marks or die "close $marks_file: $!";
}

my $mark = 0;
for my $seed (0..64) {
	my ($parents, $dates, $pairs) = generate($seed);
	my @marks = map { ++$mark } @$parents;
	if ($command eq 'generate') {
		for my $i (0..$#$parents) {
			my $message = "seed $seed c$i\n";
			print "commit refs/heads/seed-$seed/c$i\n",
				"mark :$marks[$i]\n",
				"committer A <a\@example.com> $dates->[$i] +0000\n",
				"data ", length($message), "\n", $message;
			my @p = @{$parents->[$i]};
			print "from :$marks[shift @p]\n" if @p;
			print "merge :$marks[$_]\n" for @p;
			print "\n";
		}
		next;
	}

	my @oids = map { $oid{$_} || die "missing mark $_\n" } @marks;
	my %name = map { $oids[$_] => "c$_" } 0..$#oids;
	for my $pair (@$pairs) {
		my ($a, $b) = @$pair;
		my @best = best_common_ancestors($parents, $a, $b);
		my @expect = sort map { $oids[$_] } @best;
		for my $all (1, 0) {
			my @args = ('merge-base', $all ? ('--all') : (),
				$oids[$a], $oids[$b]);
			open my $out, '-|', 'git', @args or die "git @args: $!";
			chomp(my @actual = <$out>);
			close $out;
			my $status = $?;
			my $ok = $status == (@best ? 0 : 256);
			if ($all || !@best) {
				$ok &&= join(' ', sort @actual) eq join(' ', @expect);
			} else {
				$ok &&= @actual == 1 && grep { $_ eq $actual[0] } @expect;
			}
			next if $ok;
			my $option = $all ? ' --all' : '';
			my @names = map { $name{$_} || $_ } @actual;
			die "seed=$seed mode=$mode: merge-base$option c$a c$b\n",
				"expected best: ", join(' ', map { "c$_" } @best), "\n",
				"actual: @names (wait status $status)\n",
				map {
					"c$_ \@$dates->[$_] parents=" .
					join(',', @{$parents->[$_]}) . "\n"
				} 0..$#$parents;
		}
	}
}
