export function init(ctx, payload) {
  ctx.importCSS("main.css");

  const root = ctx.root;
  let models = payload.models || [];
  let selectedModel = payload.model || "";
  let messages = payload.messages || [];
  let isLoading = payload.loading || false;
  let currentResponse = "";

  // Create UI elements
  root.innerHTML = `
    <div class="app">
      <div class="header">
        <h3>Vibe - Chat with LLM</h3>
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
      <div class="chat-container">
        <div id="chat-messages" class="chat-messages">
          ${renderMessages(messages)}
        </div>
      </div>
      <div class="input-container">
        <textarea
          id="message-input"
          placeholder="Type your message here..."
          ${isLoading ? 'disabled' : ''}
        ></textarea>
        <div class="actions">
          <button id="clear-btn" class="secondary-btn" ${isLoading ? 'disabled' : ''}>
            Clear Chat
          </button>
          <div id="loading-indicator" class="spinner-container ${isLoading ? 'visible' : 'hidden'}">
            <div class="spinner"></div>
          </div>
          <button id="send-btn" ${isLoading ? 'disabled' : ''}>
            ${isLoading ? 'Sending...' : 'Send'}
          </button>
        </div>
      </div>
    </div>
  `;

  // Get references to DOM elements
  const modelSelect = root.querySelector('#model-select');
  const chatMessages = root.querySelector('#chat-messages');
  const messageInput = root.querySelector('#message-input');
  const sendBtn = root.querySelector('#send-btn');
  const clearBtn = root.querySelector('#clear-btn');
  const loadingIndicator = root.querySelector('#loading-indicator');
  const errorAlertBox = root.querySelector('.error-alert-box');

  // Initialize error state
  updateErrorBox(payload.error_message);

  // Event handlers
  modelSelect.addEventListener('change', (event) => {
    selectedModel = event.target.value;
    ctx.pushEvent("update_model", { model: selectedModel });
  });

  messageInput.addEventListener('keydown', (event) => {
    // Send message on Ctrl+Enter or Cmd+Enter
    if ((event.ctrlKey || event.metaKey) && event.key === 'Enter') {
      event.preventDefault();
      sendMessage();
    }
  });

  sendBtn.addEventListener('click', () => {
    sendMessage();
  });

  clearBtn.addEventListener('click', () => {
    if (!isLoading) {
      ctx.pushEvent("clear_chat", {});
      messages = [];
      currentResponse = "";
      updateChatMessages();
      updateErrorBox(null); // Clear error on clear chat
    }
  });

  function sendMessage() {
    const message = messageInput.value.trim();
    if (!isLoading && selectedModel && message) {
      setLoading(true);

      // Add user message to UI immediately
      messages.push({ role: "user", content: message });
      updateChatMessages();

      // Clear input
      messageInput.value = "";

      // Add a placeholder for the assistant's response
      currentResponse = "";
      appendAssistantPlaceholder();

      // Send to server
      ctx.pushEvent("send_message", { message });

      // Clear error on send
      updateErrorBox(null);
    }
  }

  // Handle model updates from the server
  ctx.handleEvent("update_models", ({ models: newModels }) => {
    models = newModels;
    updateModelSelect();
  });

  // Handle message sent event
  ctx.handleEvent("message_sent", ({ messages: updatedMessages }) => {
    messages = updatedMessages;
    updateChatMessages();
    appendAssistantPlaceholder();
  });

  // Handle response chunks for streaming
  ctx.handleEvent("response_chunk", ({ chunk }) => {
    currentResponse += chunk;
    updateAssistantResponse(currentResponse);
    // Auto-scroll to bottom
    chatMessages.scrollTop = chatMessages.scrollHeight;
  });

  // Handle chat complete event
  ctx.handleEvent("chat_complete", ({ messages: updatedMessages }) => {
    messages = updatedMessages;
    currentResponse = "";
    updateChatMessages();
    setLoading(false);
  });

  // Handle chat cleared event
  ctx.handleEvent("chat_cleared", () => {
    messages = [];
    currentResponse = "";
    updateChatMessages();
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

  function updateChatMessages() {
    chatMessages.innerHTML = renderMessages(messages);
    chatMessages.scrollTop = chatMessages.scrollHeight;
  }

  function appendAssistantPlaceholder() {
    const placeholder = document.createElement('div');
    placeholder.className = 'message assistant-message';
    placeholder.id = 'assistant-response-placeholder';
    placeholder.innerHTML = `
      <div class="message-content">
        <div class="typing-indicator">
          <span></span><span></span><span></span>
        </div>
      </div>
    `;
    chatMessages.appendChild(placeholder);
    chatMessages.scrollTop = chatMessages.scrollHeight;
  }

  function updateAssistantResponse(text) {
    const placeholder = document.getElementById('assistant-response-placeholder');
    if (placeholder) {
      placeholder.innerHTML = `
        <div class="message-content">
          ${formatMessageContent(text)}
        </div>
      `;
    }
  }

  function renderMessages(messageList) {
    if (messageList.length === 0) {
      return `<div class="empty-chat">Select a model and start chatting</div>`;
    }

    return messageList.map(message => {
      const isUser = message.role === 'user';
      return `
        <div class="message ${isUser ? 'user-message' : 'assistant-message'}">
          <div class="message-content">
            ${formatMessageContent(message.content)}
          </div>
        </div>
      `;
    }).join('');
  }

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

  function escapeHtml(unsafe) {
    return unsafe
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#039;");
  }

  function setLoading(loading) {
    isLoading = loading;
    sendBtn.textContent = loading ? 'Sending...' : 'Send';
    sendBtn.disabled = loading;
    clearBtn.disabled = loading;
    modelSelect.disabled = loading;
    messageInput.disabled = loading;
    loadingIndicator.classList.toggle('visible', loading);
    loadingIndicator.classList.toggle('hidden', !loading);
  }

  function updateErrorBox(errorMessage) {
    if (errorMessage) {
      errorAlertBox.textContent = errorMessage;
      errorAlertBox.style.display = 'block';
    } else {
      errorAlertBox.textContent = '';
      errorAlertBox.style.display = 'none';
    }
  }

  // Handle synchronization
  ctx.handleSync(() => {
    // Ensure any pending changes are sent to the server
    ctx.pushEvent("update_model", { model: modelSelect.value });
  });
}
