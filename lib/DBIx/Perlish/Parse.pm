package DBIx::Perlish::Parse;
# $Id$
use 5.008;
use warnings;
use strict;

our $DEVEL;

use B;
use Data::Dumper;
use Carp;

sub bailout
{
	my ($S, @rest) = @_;
	if ($DEVEL) {
		confess @rest;
	} else {
		my $args = join '', @rest;
		$args = "Something's wrong" unless $args;
		my $file = $S->{file};
		my $line = $S->{line};
		$args .= " at $file line $line.\n"
			unless substr($args, length($args) -1) eq "\n";
		CORE::die($args);
	}
}

# "is" checks

sub is
{
	my ($optype, $op, $name) = @_;
	return 0 unless ref($op) eq $optype;
	return 1 unless $name;
	return $op->name eq $name;
}

sub gen_is
{
	my ($optype) = @_;
	my $pkg = "B::" . uc($optype);
	eval qq[ sub is_$optype { is("$pkg", \@_) } ];
}

gen_is("op");
gen_is("cop");
gen_is("unop");
gen_is("listop");
gen_is("svop");
gen_is("null");
gen_is("binop");
gen_is("logop");

sub is_const
{
	my ($S, $op) = @_;
	return () unless is_svop($op, "const");
	my $sv = $op->sv;
	if (!$$sv) {
		$sv = $S->{padlist}->ARRAYelt($op->targ);
	}
	if (wantarray) {
		return (${$sv->object_2svref}, $sv);
	} else {
		return ${$sv->object_2svref};
	}
}

# "want" helpers

sub gen_want
{
	my ($optype, $return) = @_;
	if (!$return) {
		$return = '$op';
	} elsif ($return =~ /^\w+$/) {
		$return = '$op->' . $return;
	}
	eval <<EOF;
	sub want_$optype {
		my (\$S, \$op, \$n) = \@_;
		unless (is_$optype(\$op, \$n)) {
			bailout \$S, "want $optype" unless \$n;
			bailout \$S, "want $optype \$n";
		}
		$return;
	}
EOF
}

gen_want("op");
gen_want("unop", "first");
gen_want("listop", 'get_all_children($op)');
gen_want("svop", "sv");
gen_want("null");

sub want_const
{
	my ($S, $op) = @_;
	my $sv = want_svop($S, $op, "const");
	if (!$$sv) {
		$sv = $S->{padlist}->ARRAYelt($op->targ);
	}
	${$sv->object_2svref};
}

sub want_method
{
	my ($S, $op) = @_;
	my $sv = want_svop($S, $op, "method_named");
	if (!$$sv) {
		$sv = $S->{padlist}->ARRAYelt($op->targ);
	}
	${$sv->object_2svref};
}

# getters

sub get_all_children
{
	my ($op) = @_;
	my $c = $op->children;
	my @op;
	return @op unless $c;
	push @op, $op->first;
	while (--$c) {
		push @op, $op[-1]->sibling;
	}
	@op;
}

sub get_table
{
	my ($S, $op) = @_;
	want_const($S, $op);
}

sub get_var
{
	my ($S, $op) = @_;
	if (ref($op) eq "B::OP" && $op->name eq "padsv") {
		return "my #" . $op->targ;
	} elsif (ref($op) eq "B::UNOP" && $op->name eq "null") {
		$op = $op->first;
		want_svop($S, $op, "gvsv");
		return "*" . $op->gv->NAME;
	} else {
	# XXX
		print "$op\n";
		print "type: ", $op->type, "\n";
		print "name: ", $op->name, "\n";
		print "desc: ", $op->desc, "\n";
		print "targ: ", $op->targ, "\n";
		bailout $S, "cannot get var";
	}
}

sub get_tab_field
{
	my ($S, $unop) = @_;
	my $op = want_unop($S, $unop, "entersub");
	want_op($S, $op, "pushmark");
	$op = $op->sibling;
	my $tab = is_const($S, $op);
	if ($tab) {
		$tab = new_tab($S, $tab);
	} elsif (is_op($op, "padsv")) {
		my $var = "my #" . $op->targ;
		$tab = $S->{var_alias}{$var};
	}
	unless ($tab) {
		bailout $S, "cannot get a table";
	}
	$op = $op->sibling;
	my $field = want_method($S, $op);
	$op = $op->sibling;
	want_null($S, $op);
	($tab, $field);
}

# helpers

sub new_tab
{
	my ($S, $tab) = @_;
	unless ($S->{tabs}{$tab}) {
		$S->{tabs}{$tab} = 1;
		$S->{tab_alias}{$tab} = $S->{alias};
		$S->{alias}++;
	}
	$S->{tab_alias}{$tab};
}

sub new_var
{
	my ($S, $var, $tab) = @_;
	bailout $S, "cannot reuse $var for table $tab, it's already used by $S->{vars}{$var}"
		if $S->{vars}{$var};
	$S->{vars}{$var} = $tab;
	$S->{var_alias}{$var} = $S->{alias};
	$S->{alias}++;
}

# parsers

sub try_parse_attr_assignment
{
	my ($S, $op) = @_;
	return unless is_unop($op, "entersub");
	$op = want_unop($S, $op);
	return unless is_op($op, "pushmark");
	$op = $op->sibling;
	return unless is_const($S, $op) eq "attributes";
	$op = $op->sibling;
	return unless is_const($S, $op);
	$op = $op->sibling;
	return unless is_unop($op, "srefgen");
	my $op1 = want_unop($S, $op);
	$op1 = want_unop($S, $op1) if is_unop($op1, "null");
	return unless is_op($op1, "padsv");
	my $varn = "my #" . $op1->targ;
	$op = $op->sibling;
	my $attr = is_const($S, $op);
	return unless $attr;
	$op = $op->sibling;
	return unless is_svop($op, "method_named");
	return unless want_method($S, $op, "import");
	new_var($S, $varn, $attr);
	return $attr;
}

sub parse_list
{
	my ($S, $op) = @_;
	my @op = get_all_children($op);
	for $op (@op) {
		parse_op($S, $op);
	}
}

sub parse_return
{
	my ($S, $op) = @_;
	my @op = get_all_children($op);
	bailout "there should be at most one return statement" if $S->{returns};
	$S->{returns} = [];
	my $last_alias;
	for $op (@op) {
		my %rv = parse_return_value($S, $op);
		if (exists $rv{field}) {
			if (defined $last_alias) {
				push @{$S->{returns}}, "$rv{field} as $last_alias";
				undef $last_alias;
			} else {
				push @{$S->{returns}}, $rv{field};
			}
		} elsif (exists $rv{alias}) {
			bailout "bad alias name \"$rv{alias}\""
				unless $rv{alias} =~ /^\w+$/;
			bailout "cannot alias an alias"
				if defined $last_alias;
			$last_alias = $rv{alias};
		}
	}
}

sub parse_return_value
{
	my ($S, $op) = @_;

	if (is_unop($op, "entersub")) {
		my ($t, $f) = get_tab_field($S, $op);
		return field => "$t.$f";
	} elsif (my $const = is_const($S, $op)) {
		return alias => $const;
	} elsif (is_op($op, "pushmark")) {
		return ();
	} else {
		bailout "error parsing return values";
	}
}

sub parse_term
{
	my ($S, $op) = @_;

	if (is_unop($op, "entersub")) {
		my ($t, $f) = get_tab_field($S, $op);
		return "$t.$f";
	} elsif (is_binop($op)) {
		my $expr = parse_expr($S, $op);
		return "($expr)";
	} elsif (my ($const,$sv) = is_const($S, $op)) {
		if (ref $sv eq "B::IV" || ref $sv eq "B::NV") {
			# This is surely a number, so we can
			# safely inline it in the SQL.
			return $const;
		} else {
			# This will probably be represented by a string,
			# we'll let DBI to handle the quoting of a bound
			# value.
			push @{$S->{values}}, $const;
			return "?";
		}
	} elsif (is_op($op, "padsv")) {
		my $var = "my #" . $op->targ;
		if ($S->{var_alias}{$var}) {
			bailout $S, "cannot use table variable as a term";
		}
		my $vv = $S->{padlist}->ARRAYelt($op->targ)->object_2svref;
		push @{$S->{values}}, $$vv;
		return "?";
	} else {
		bailout $S, "cannot reconstruct term from operation \"",
				$op->name, '"';
	}
}

sub parse_simple_term
{
	my ($S, $op) = @_;
	if (my $const = is_const($S, $op)) {
		return $const;
	} elsif (is_op($op, "padsv")) {
		my $var = "my #" . $op->targ;
		if ($S->{var_alias}{$var}) {
			bailout $S, "cannot use table variable as a simple term";
		}
		my $vv = $S->{padlist}->ARRAYelt($op->targ)->object_2svref;
		return $$vv;
	} else {
		bailout $S, "cannot reconstruct simple term from operation \"",
				$op->name, '"';
	}
}

sub try_parse_subselect
{
	my ($S, $sop) = @_;
	my $sub = $sop->last->first;
	return unless is_unop($sub, "entersub");
	$sub = $sub->first if is_unop($sub->first, "null");
	return unless is_op($sub->first, "pushmark");

	my $rg = $sub->first->sibling;
	return if is_null($rg);
	my $dbfetch = $rg->sibling;
	return if is_null($dbfetch);
	return unless is_null($dbfetch->sibling);

	return unless is_unop($rg, "refgen");
	$rg = $rg->first if is_unop($rg->first, "null");
	return unless is_op($rg->first, "pushmark");
	my $codeop = $rg->first->sibling;
	return unless is_svop($codeop, "anoncode");

	$dbfetch = $dbfetch->first if is_unop($dbfetch->first, "null");
	$dbfetch = $dbfetch->first;
	return unless is_svop($dbfetch, "gv");
	return unless is_null($dbfetch->sibling);

	my $gv = $dbfetch->sv;
	if (!$$gv) {
		$gv = $S->{padlist}->ARRAYelt($dbfetch->targ);
	}
	return unless ref $gv eq "B::GV";
	return unless $gv->NAME eq "db_fetch";

	my $cv = $codeop->sv;
	if (!$$cv) {
		$cv = $S->{padlist}->ARRAYelt($codeop->targ);
	}
	my $subref = $cv->object_2svref;

	# XXX This should be able to handle situations
	# when internal select refers to external things.
	# This might be easy, or it might be not.
	my %gen_args = %{$S->{gen_args}};
	if ($gen_args{prefix}) {
		$gen_args{prefix} = "$gen_args{prefix}_$S->{subselect}";
	} else {
		$gen_args{prefix} = $S->{subselect};
	}
	$S->{subselect}++;
	my ($sql, $vals, $nret) = DBIx::Perlish::gen_sql($subref, "select", %gen_args);
	if ($nret != 1) {
		bailout $S, "subselect query sub must return exactly one value\n";
	}

	my $left = parse_term($S, $sop->first);
	push @{$S->{values}}, @$vals;
	return "$left in ($sql)";
}

my %binop_map = (
	eq       => "=",
	seq      => "=",
	ne       => "<>",
	sne      => "<>",
	slt      => "<",
	gt       => ">",
	sgt      => ">",
	le       => "<=",
	sle      => "<=",
	ge       => ">=",
	sge      => ">=",
	add      => "+",
	subtract => "-",
	multiply => "*",
	divide   => "/",
);

sub parse_expr
{
	my ($S, $op) = @_;
	my $sqlop;
	if ($sqlop = $binop_map{$op->name}) {
		my $left = parse_term($S, $op->first);
		my $right = parse_term($S, $op->last);

		return "$left $sqlop $right";
	} elsif ($op->name eq "lt") {
		if (is_unop($op->last, "negate")) {
			my $r = try_parse_subselect($S, $op);
			return $r if $r;
		}
		# if the "subselect theory" fails, try a normal binop
		my $left = parse_term($S, $op->first);
		my $right = parse_term($S, $op->last);
		return "$left < $right";
	} else {
		bailout $S, "unsupported binop " . $op->name;
	}
}

sub parse_entersub
{
	my ($S, $op) = @_;
	my $tab = try_parse_attr_assignment($S, $op);
	bailout $S, "cannot parse entersub" unless $tab;
}

sub try_parse_range
{
	my ($S, $op) = @_;
	return try_parse_range($S, $op->first) if is_unop($op, "null");
	return unless is_unop($op, "flop");
	$op = $op->first;
	return unless is_unop($op, "flip");
	$op = $op->first;
	return unless is_logop($op, "range");
	return (parse_simple_term($S, $op->first),
			parse_simple_term($S, $op->other));
}

sub parse_or
{
	my ($S, $op) = @_;
	if (is_op($op->other, "last")) {
		my ($from, $to) = try_parse_range($S, $op->first);
		bailout $S, "range operator expected" unless defined $to;
		$S->{offset} = $from;
		$S->{limit}  = $to-$from+1;
	} else {
		bailout $S, "\"or\" is not supported at the moment";
	}
}

sub parse_op
{
	my ($S, $op) = @_;

	if (is_listop($op, "list")) {
		parse_list($S, $op);
	} elsif (is_listop($op, "lineseq")) {
		parse_list($S, $op);
	} elsif (is_listop($op, "return")) {
		parse_return($S, $op);
	} elsif (is_binop($op)) {
		push @{$S->{where}}, parse_expr($S, $op);
	} elsif (is_logop($op, "or")) {
		parse_or($S, $op);
	} elsif (is_unop($op, "leavesub")) {
		parse_op($S, $op->first);
	} elsif (is_unop($op, "null")) {
		parse_op($S, $op->first);
	} elsif (is_op($op, "padsv")) {
		# XXX Skip for now, it is either a variable
		# that does not represent a table, or else
		# it is already associated with a table in $S.
	} elsif (is_op($op, "pushmark")) {
		# skip
	} elsif (is_cop($op, "nextstate")) {
		$S->{file} = $op->file;
		$S->{line} = $op->line;
		# skip
	} elsif (is_cop($op)) {
		# XXX any other things?
		$S->{file} = $op->file;
		$S->{line} = $op->line;
		# skip
	} elsif (is_unop($op, "entersub")) {
		parse_entersub($S, $op);
	} elsif (ref($op) eq "B::PMOP" && $op->name eq "match") {
		my $like = $op->precomp;
		$like = "%$like" unless $like =~ s|^\^||;
		$like = "$like%" unless $like =~ s|\$$||;
		my ($tab, $field) = get_tab_field($S, $op->first);
		push @{$S->{where}}, "$tab.$field like '$like'";
	} else {
		print "$op\n";
		if (ref($op) eq "B::PMOP") {
			print "reg: ", $op->precomp, "\n";
		}
		print "type: ", $op->type, "\n";
		print "name: ", $op->name, "\n";
		print "desc: ", $op->desc, "\n";
		print "targ: ", $op->targ, "\n";
	}
}

sub parse_sub
{
	my ($S, $sub) = @_;
	if ($DEVEL) {
		$Carp::Verbose = 1;
		require B::Concise;
		my $walker = B::Concise::compile('-terse', $sub);
		print "CODE DUMP:\n";
		$walker->();
		print "\n\n";
	}
	my $root = B::svref_2object($sub);
	$S->{padlist} = $root->PADLIST->ARRAY;
	$root = $root->ROOT;
	parse_op($S, $root);
}

sub init
{
	my %args = @_;
	my $S = {
		gen_args  => \%args,
		file      => '??',
		line      => '??',
		subselect => 's01',
	};
	$S->{alias} = $args{prefix} ? "$args{prefix}_t01" : "t01";
	$S;
}

# Borrowed from IO::All by Ingy döt Net.
my $old_warn_handler = $SIG{__WARN__}; 
$SIG{__WARN__} = sub { 
	if ($_[0] !~ /^Useless use of .+ \(.+\) in void context/) {
		goto &$old_warn_handler if $old_warn_handler;
		warn(@_);
	}
};

1;
