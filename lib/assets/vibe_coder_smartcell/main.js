export function init(ctx, payload) {
  ctx.importCSS("main.css");

  const root = ctx.root;
  let models = payload.models || [];
  let selectedModel = payload.model || "";
  let prompt = payload.prompt || "";
  let isLoading = payload.loading || false;
  let generatedCode = payload.source || "";

  // Create UI elements
  root.innerHTML = `
    <div class="app">
      <div class="header">
        <h3>Vibe - Elixir Code Generator</h3>
      </div>
      <pre class="error-alert-box">Alert box</pre>
      <div class="model-selector">
        <label for="model-select">Model:</label>
        <select id="model-select" ${isLoading ? 'disabled' : ''}>
          <option value="" disabled ${!selectedModel ? 'selected' : ''}>Select a model</option>
          ${models.map(model => `
            <option value="${model.id}" ${model.id === selectedModel ? 'selected' : ''}>
              ${model.name}
            </option>
          `).join('')}
        </select>
      </div>
      <div class="prompt-container">
        <label for="prompt-textarea">Prompt:</label>
        <textarea
          id="prompt-textarea"
          placeholder="Describe the Elixir code you want to generate..."
          ${isLoading ? 'disabled' : ''}
        >${prompt}</textarea>
      </div>
      <div class="actions">
        <div id="loading-indicator" class="spinner-container ${isLoading ? 'visible' : 'hidden'}">
          <div class="spinner"></div>
        </div>
        <button id="generate-btn" class="${isLoading ? 'loading' : ''}">
          ${isLoading ? 'Generating...' : 'Generate Code'}
        </button>
      </div>
      <div class="code-container">
        <label for="code-textarea">Generated Code:</label>
        <textarea
          id="code-textarea"
          placeholder="Generated code will appear here..."
          ${isLoading ? 'disabled' : ''}
          autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false"
        >${generatedCode}</textarea>
      </div>
    </div>
  `;

  // Get references to DOM elements
  const modelSelect = root.querySelector('#model-select');
  const promptTextarea = root.querySelector('#prompt-textarea');
  const codeTextarea = root.querySelector('#code-textarea');
  const generateBtn = root.querySelector('#generate-btn');
  const loadingIndicator = root.querySelector('#loading-indicator');
  const errorAlertBox = root.querySelector('.error-alert-box');

  // Initialize error state
  updateErrorBox(payload.error_message);

  // Event handlers
  modelSelect.addEventListener('change', (event) => {
    selectedModel = event.target.value;
    ctx.pushEvent("update_model", { model: selectedModel });
  });

  promptTextarea.addEventListener('input', (event) => {
    prompt = event.target.value;
    ctx.pushEvent("update_prompt", { prompt });
  });

  codeTextarea.addEventListener('input', (event) => {
    generatedCode = event.target.value;
    ctx.pushEvent("update_source", { source: generatedCode });
  });

  generateBtn.addEventListener('click', () => {
    if (!isLoading && selectedModel && prompt.trim()) {
      setLoading(true);
      codeTextarea.value = ""; // Clear before generating
      updateErrorBox(null); // Clear error on generate
      ctx.pushEvent("generate", {});
    }
  });

  // Handle model updates from the server
  ctx.handleEvent("update_models", ({ models: newModels }) => {
    models = newModels;
    updateModelSelect();
  });

  // Handle generation started event
  ctx.handleEvent("generation_started", () => {
    setLoading(true);
    codeTextarea.value = "";
  });

  // Handle code chunks for streaming (append directly to codeTextarea)
  ctx.handleEvent("code_chunk", ({ chunk }) => {
    codeTextarea.value += chunk;
    // Auto-scroll to bottom
    codeTextarea.scrollTop = codeTextarea.scrollHeight;
  });

  // Handle generation complete event
  ctx.handleEvent("generation_complete", ({ source }) => {
    generatedCode = source;
    codeTextarea.value = source;
    setLoading(false);
  });

  // Handle error updates
  ctx.handleEvent("update_error", ({ error_message }) => {
    updateErrorBox(error_message);
  });

  // Helper functions
  function updateModelSelect() {
    modelSelect.innerHTML = `
      <option value="" disabled ${!selectedModel ? 'selected' : ''}>Select a model</option>
      ${models.map(model => `
        <option value="${model.id}" ${model.id === selectedModel ? 'selected' : ''}>
          ${model.name}
        </option>
      `).join('')}
    `;
  }

  function setLoading(loading) {
    isLoading = loading;
    generateBtn.textContent = loading ? 'Generating...' : 'Generate Code';
    generateBtn.classList.toggle('loading', loading);
    modelSelect.disabled = loading;
    promptTextarea.disabled = loading;
    codeTextarea.disabled = loading;
    loadingIndicator.classList.toggle('visible', loading);
    loadingIndicator.classList.toggle('hidden', !loading);
  }

  function updateErrorBox(errorMessage) {
    if (errorMessage) {
      // Use innerHTML to render potential markdown/code in error messages
      errorAlertBox.innerHTML = formatMessageContent(errorMessage);
      errorAlertBox.style.display = 'block';
    } else {
      errorAlertBox.innerHTML = '';
      errorAlertBox.style.display = 'none';
    }
  }

  // Basic formatter for error messages (can be expanded)
  function formatMessageContent(content) {
    // Convert markdown-style code blocks to HTML
    let formatted = content.replace(/```(\w*)([\s\S]*?)```/g, (match, language, code) => {
      return `<pre class="code-block ${language}"><code>${escapeHtml(code.trim())}</code></pre>`;
    });
    // Convert single backtick inline code
    formatted = formatted.replace(/`([^`]+)`/g, '<code>$1</code>');
    // Convert line breaks to <br>
    formatted = formatted.replace(/\n/g, '<br>');
    return formatted;
  }

  // *** Corrected escapeHtml function (using Unicode escapes) ***
  function escapeHtml(unsafe) {
    return unsafe
      .replace(/&/g, "\u0026amp;") // &
      .replace(/</g, "\u0026lt;")   // <
      .replace(/>/g, "\u0026gt;")   // >
      .replace(/"/g, "\u0026quot;") // "
      .replace(/'/g, "&#039;");  // Keep as is
  }

  // Handle synchronization
  ctx.handleSync(() => {
    // Ensure any pending changes are sent to the server
    ctx.pushEvent("update_model", { model: modelSelect.value });
    ctx.pushEvent("update_prompt", { prompt: promptTextarea.value });
    ctx.pushEvent("update_source", { source: codeTextarea.value });
  });
}
