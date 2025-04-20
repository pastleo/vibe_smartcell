# Vibe Smartcell

![demo-1](./docs/demo-1.png)

![demo-2](./docs/demo-2.png)

![demo-3](./docs/demo-3.png)

## Installation

Add these lines to `Notebook dependencies and setup` to install package and set config

```elixir
Mix.install([
  {:vibe_smartcell, git: "https://github.com/pastleo/vibe_smartcell.git", tag: "0.2.1"},
])
```

Then add `Vibe` smartcell:

![get-started](./docs/get-started.png)

When no llm provider is configured, example will be presented by the smartcell:

![config-example](./docs/config-example.png)
