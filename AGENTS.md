# sitemap-spider - AI Agent Instructions

**sitemap-spider** is a Coldbox module designed to generate website sitemaps.

This document provides an overview of the project structure, conventions, dependencies, and AI integration guidelines for agents working on this codebase. It is designed to be a living document that evolves with the project, so please refer back to it as needed and update it if you make changes that affect the information contained herein.

## Stack

- **Language:** CFML (ColdFusion Markup Language)
- **Framework:** ColdBox 8.x (MVC, Dependency Injection via WireBox)
- **Engines:** Adobe ColdFusion 2023+, Lucee 5, 6, and Boxlang 1 (CFML compat)
- **Test Framework:** TestBox 7.x (BDD-style specs. Unit, integration, and contract tests)
- **Package Manager:** CommandBox (ForgeBox dependencies in `box.json`)
- **Port:** 61002 (configured in each `server-*.json`)

## Core Application Structure

All application code lives in `models/`. The crawl runs through this call flow:

`SitemapService.create()` → `Crawler.crawl()` (breadth-first queue) →
`models/browsers/Jsoup.fetchUrl()` (jsoup loaded via cbjavaloader) → `Parser`
(extracts links, canonical URL, last-modified, nofollow) →
`SitemapGenerator.generate()` → XML string.

The browser backend that fetches each URL is selected by the `browserDsl` module
setting in `ModuleConfig.cfc` (default `Jsoup@sitemap-spider`). Browser
implementations live in `models/browsers/` and share the `IBrowser` interface.

The same crawl also feeds an optional broken link report:
`Crawler` records each failure with its HTTP status, reason, and the pages that
link to it → `LinkReportGenerator.generate()` → JSON saved beside the sitemap
when `writeLinkReport` is on. Turning on `checkAssets` adds a second phase after
the page crawl that calls `IBrowser.checkUrl()` once per unique on-host asset.
Assets never become pages and never reach the sitemap XML.

Two contract details the report depends on:

- `fetchUrl()` throws `StatusCodeException` with `errorCode` set to the HTTP
  status and `extendedInfo` set to JSON holding `status`, `url`, and `chain`.
  `Crawler.classifyFetchError()` reads them and degrades to `status: 0` /
  `reason: "unknown"` when a backend omits them.
- `checkUrl()` never throws. It returns
  `{ ok, status, url, redirectChain, error }` for every URL.

## Key Dependencies and Modules

- **Runtime:** `cbjavaloader` is the only runtime dependency (`box.json`,
  `ModuleConfig.cfc`). Its `onLoad()` loads the jsoup jar from `lib/` so the
  Jsoup browser can parse HTML.

## Project-Specific Conventions

### Code Style

- **Handler naming:** Plural nouns (Users.cfc, Orders.cfc)
- **Dependency injection:** Use `property name="service" inject` over manual getInstance()
- **Singletons:** Gateways, clients, services are `singleton` scope (one instance per app lifecycle)
- **DI:** Use `property inject="..."` for WireBox injection. Use `provider:` prefix for lazy/virtual injection. When injecting Qb's `queryBuilder` always use `provider:QueryBuilder@qb` to avoid shared state issues and always return a fresh instance. Place injected properties below the regular, persisted, properties.
- **Naming:** PascalCase for components, camelCase for methods/variables. Gateway methods match API actions (e.g., `addQuote`).
- **Logging:** LogBox logger injected via `property name="logger" inject="logbox:logger:{this}"`. Use `logger.error()` for failures.
- **Member Functions** Use CFML member functions, when available over passing variables into the function. Example: prefer `myArray.append(value)` over `arrayAppend(myArray, value)`. The only exception is when writing tests and using loops/each. In those cases, prefer `for` loops for better stack traces. Example: prefer `for ( ar item in myArray ) { ... }` over `myArray.each( function( item ) { ... } )` or prefer `for ( var key in myStruct ) { ... }` over `myStruct.each( function( key, value ) { ... }`.
- **CFML Structs** When checking for key existence, use the member function `keyExists()` instead of `structKeyExists()` always. Example: prefer `myStruct.keyExists( "key" )` over `structKeyExists( myStruct, "key" )`.
- **Method Comments:** Every method in a component (public and private) should have a docblock comment above it describing its purpose and any non-obvious behavior. Keep them concise — one short paragraph or a few bullet points is sufficient.
- **Handler Scopes:** `rc` = raw request input only (use `param` for defaults, never mutate). `prc` = all normalized/validated/derived values. `var`/`local` = throwaway intermediates only.
- **Avoid Value Pairs Routing**: Set `valuePairTranslation( false )` and avoid extra name-value pairs in the URL. Example: prefer `/users/123` over `/users/id/123`. 
- **Do not run cfformat** - The user will run it manually when needed.

### Gotchas to watch out for

- **DI Availability:** When injecting a property with `inject="..."`, the property is not available in the `init()` method. If you need to perform setup that requires injected dependencies, use the `onDiComplete()` method instead, which is called by WireBox after injection is complete.

## Testing

### Running Tests

```bash
# Start the server (Lucee 6 shown; see box.json scripts for other engines)
box server start serverConfigFile=server-lucee@6.json

# Run all tests via browser
http://localhost:61002/tests/runner.cfm

# Run tests from the CLI using the `box testbox run` command.
# Use the `bundles` argument with dot-delimited paths (no .cfc extension).
# You can run multiple test bundles at once by comma-separating them:
box testbox run runner="http://localhost:61002/tests/runner.cfm" bundles="tests.specs.ModuleSpec" verbose=false
```

## AI Integration

This project includes AI-powered development assistance with guidelines, skills, and MCP documentation servers.

### Directory Structure

```
/.agents/
  /manifest.json       - AI configuration (language, agents, guidelines, skills, MCP servers)
  /guidelines/         - Framework documentation and best practices
    /core/             - Core ColdBox/BoxLang guidelines
    /modules/          - Module-specific guidelines
    /custom/           - Your custom guidelines
    /overrides/        - Override core guidelines
  /skills/             - Implementation cookbooks (how-to guides)
    /{name}/           - One folder per skill (flat, no subdirectories)
      SKILL.md         - Skill content (fetched from registry or created locally)
  /skills-custom/      - Additional tracked skills (how-to guides)
    /{name}/           - One folder per skill (flat, no subdirectories)
      SKILL.md         - Skill content (fetched from registry or created locally)
/.mcp.json             - MCP server configurations (core, module, custom)
```

### Manifest

The `.agents/manifest.json` file contains the complete AI integration configuration:

**Reading the manifest** helps you understand available resources and project configuration.

### Using Guidelines & Skills

Guidelines and skills are stored locally in `.agents/`. Load them explicitly when you need framework fundamentals via `read_file`. 

**Core Guidelines** (`.agents/guidelines/core/`) — `read_file` on `.agents/guidelines/core/coldbox.md` — ColdBox frameworkconventions, handler/routing/DI reference
**Module Guidelines** — load by name on request from `.agents/guidelines/modules/`.
**Skills** (`.agents/skills/{name}/SKILL.md`) — step-by-step implementation patterns. See manifest for skill names and descriptions.
**Skills (Custom)** (`.agents/skills-custom/{name}/SKILL.md`) — more step-by-step implementation patterns. See manifest for skill names and descriptions.