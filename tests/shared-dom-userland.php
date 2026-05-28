<?php

function expect_true(bool $condition, string $message): void
{
    if (!$condition) {
        fwrite(STDERR, $message . PHP_EOL);
        exit(1);
    }
}

expect_true(extension_loaded('dom'), 'dom extension did not load');
expect_true(class_exists(Dom\HTMLDocument::class), 'Dom\HTMLDocument is missing');

$html = <<<'HTML'
<!doctype html>
<html>
<head>
    <meta charset="Windows-1252">
    <title>Shared DOM check</title>
</head>
<body>
    <main id="app">
        <article class="post selected" data-kind="news">
            <h1>Hello &amp; goodbye</h1>
            <p class="lead">shared-dom-ok</p>
            <div class="wrapper"><div></div></div>
            <span>1</span><span>2</span><span>3</span>
        </article>
    </main>
</body>
</html>
HTML;

$document = Dom\HTMLDocument::createFromString($html, LIBXML_NOERROR);

expect_true(strcasecmp($document->charset, 'windows-1252') === 0, 'unexpected document charset: ' . $document->charset);

$heading = $document->querySelector('article.post[data-kind="news"] > h1');
expect_true($heading !== null, 'heading not found');
expect_true($heading->textContent === 'Hello & goodbye', 'unexpected heading text: ' . $heading->textContent);

$lead = $document->querySelector('#app article.selected > p.lead');
expect_true($lead !== null, 'lead paragraph not found');
expect_true($lead->textContent === 'shared-dom-ok', 'unexpected lead text: ' . $lead->textContent);

$following = [];
foreach ($document->querySelectorAll('div:has(div) ~ span') as $node) {
    $following[] = $node->textContent;
}
expect_true($following === ['1', '2', '3'], 'unexpected sibling selector result: ' . json_encode($following));

$lead->textContent = 'updated';
expect_true(str_contains($document->saveHtml($lead), 'updated'), 'updated DOM did not serialize as expected');

expect_true(class_exists(Uri\WhatWg\Url::class), 'Uri\\WhatWg\\Url is missing');

$url = Uri\WhatWg\Url::parse("https://\u{4F60}\u{597D}\u{4F60}\u{597D}.example/dir1/../dir2?x=1#frag");
expect_true($url instanceof Uri\WhatWg\Url, 'WHATWG URL parser returned no URL');
expect_true(
    $url->toAsciiString() === 'https://xn--6qqa088eba.example/dir2?x=1#frag',
    'unexpected WHATWG URL: ' . $url->toAsciiString()
);

echo 'shared DOM userland passed' . PHP_EOL;
