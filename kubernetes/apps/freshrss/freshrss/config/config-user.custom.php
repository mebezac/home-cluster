<?php
// Default settings for NEW FreshRSS users. FreshRSS reads this file only when it
// creates a user (the entrypoint's FRESHRSS_USER on the first start). After that,
// the live settings are data/users/<user>/config.php: change them in the UI.

return [
	// Filter actions that apply to every feed, when an article arrives.
	// FreshRSS cannot delete articles, so "blocked" = marked read on arrival.
	'filters' => [
		// Obituaries (BG Independent tags them "Obituary"; ai/ tags come from the LLM).
		['search' => '#Obituary', 'actions' => ['read']],
		['search' => '#ai/obituary', 'actions' => ['read']],
		// Deals: Wired files them under "Gear / Deals". The Verge feed has no
		// categories, so match its titles, plus the LLM tag for both sites.
		['search' => 'inurl:wired.com #"Gear / Deals"', 'actions' => ['read']],
		['search' => 'inurl:wired.com #ai/deal', 'actions' => ['read']],
		['search' => 'inurl:theverge.com #ai/deal', 'actions' => ['read']],
		['search' => 'inurl:theverge.com intitle:/(\bdeals?\b|on\ssale|lowest\sprice|cheapest|price\sdrop|%\soff|\$\d+\soff|black\sfriday|prime\sday|cyber\smonday)/i', 'actions' => ['read']],
		// Birchtree members-only posts: "+ " title prefix and the "Members" category.
		['search' => 'inurl:birchtree.me #Members', 'actions' => ['read']],
		['search' => 'inurl:birchtree.me intitle:/^\+\s/', 'actions' => ['read']],
	],

	// Saved search in the sidebar: all product reviews.
	'queries' => [
		['name' => 'Reviews', 'search' => '#ai/review OR #"Gear / Reviews"'],
	],

	// LLM tagging (Anthropic's OpenAI-compatible endpoint). The extension code is
	// mounted from ./ext; the prompt is ./config/prompt.md (copied in by the init container).
	'extensions_enabled' => ['LLM Classification' => true],
	'extensions' => [
		'LLM Classification' => [
			'api_url' => 'https://api.anthropic.com/v1',
			'api_key' => (string)getenv('LLM_API_KEY'),
			'model' => 'claude-haiku-5-5',
			'enable_tags' => true,
			'tag_prefix' => 'ai/',
			'allowed_tags' => "review\ndeal\nobituary",
			'max_content_length' => 4000,
			'max_tokens' => 1024,
			'timeout' => 30,
			'max_retries' => 2,
			'search_filter' => '',
			// false would send chat_template_kwargs, which Anthropic does not use.
			'allow_thinking' => true,
		],
	],
];
