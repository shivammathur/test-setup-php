<?php

namespace BenchmarkSupport;

function mixedWorkload() : int
{
	$records = array();
	for ($i = 0; $i < 6000; $i++) {
		$records[] = array(
			"id" => $i,
			"slug" => sprintf("record-%04d", $i),
			"name" => str_repeat(chr(65 + ($i % 26)), 8),
			"meta" => array(
				"left" => $i % 97,
				"right" => ($i * 7) % 101,
			),
		);
	}

	for ($round = 0; $round < 12; $round++) {
		$json = json_encode($records, JSON_THROW_ON_ERROR);
		$decoded = json_decode($json, true, 512, JSON_THROW_ON_ERROR);

		usort($decoded, static function(array $a, array $b) : int {
			return $a["meta"]["right"] <=> $b["meta"]["right"];
		});

		$bucket = array();
		foreach ($decoded as $row) {
			$key = preg_replace("/[^a-z0-9]+/i", "-", strtolower($row["slug"]));
			$bucket[$key] = hash("sha256", serialize($row), false);
		}

		arsort($bucket);
		$records = array();
		$slice = array_slice($bucket, 0, 1200, true);
		$nextId = 0;
		foreach ($slice as $key => $digest) {
			$parts = array_reverse(explode("-", $key));
			$left = strlen($parts[0]) % 97;
			$right = hexdec(substr($digest, 0, 2)) % 101;
			$records[] = array(
				"id" => $nextId++,
				"slug" => $key,
				"name" => substr($digest, 0, 8),
				"meta" => array(
					"left" => $left,
					"right" => $right,
				),
				"digest" => $digest,
				"parts" => $parts,
			);
		}
	}

	return count($records);
}

class A
{
	/** @var int */
	public $x = 0;

	/** @var string */
	public $s = "";
}

class B extends A
{
	/** @var float */
	public $f = 0.0;
}

function diverseWork(int $i) : array
{
	$a = new A();
	$a->x = $i;
	$a->s = "str" . $i;

	$b = new B();
	$b->f = $i * 1.5;
	$b->x = $i + 1;

	$arr = array($a, $b, $i, "key" => $a->s);
	$arr[] = $b->f;
	unset($arr["key"]);

	$result = array_map(static function($v) {
		return is_object($v) ? get_class($v) : (string) $v;
	}, $arr);

	$x = match (true) {
		$i % 3 === 0 => "fizz",
		$i % 5 === 0 => "buzz",
		default => (string) $i,
	};

	$result[] = $x;

	return $result;
}

function diverseWorkload() : int
{
	$count = 0;
	for ($i = 0; $i < 400000; $i++) {
		$count += count(diverseWork($i));
	}

	return $count;
}

class Node
{
	/** @var string */
	public $name;

	/** @var int */
	public $value;

	/** @var ?Node */
	public $left;

	/** @var ?Node */
	public $right;

	public function __construct(string $name, int $value, ?Node $left = NULL, ?Node $right = NULL)
	{
		$this->name = $name;
		$this->value = $value;
		$this->left = $left;
		$this->right = $right;
	}

	public function sum() : int
	{
		return $this->value
			+ ($this->left ? $this->left->sum() : 0)
			+ ($this->right ? $this->right->sum() : 0);
	}

	public function depth() : int
	{
		return 1 + max(
			$this->left ? $this->left->depth() : 0,
			$this->right ? $this->right->depth() : 0
		);
	}
}

function buildTree(int $depth, int $id = 0) : Node
{
	if (0 === $depth) {
		return new Node("leaf-" . $id, $id);
	}

	return new Node(
		"node-" . $id,
		$id,
		buildTree($depth - 1, 2 * $id + 1),
		buildTree($depth - 1, 2 * $id + 2)
	);
}

function oopWorkload() : int
{
	$total = 0;
	for ($i = 0; $i < 300; $i++) {
		$tree = buildTree(12);
		$total += $tree->sum();
		$total += $tree->depth();
	}

	return $total;
}

function compositeWorkload() : int
{
	return mixedWorkload() + diverseWorkload() + oopWorkload();
}
