const STATUSES = ["TODO", "IN_PROGRESS", "DONE"];
const NEXT_STATUS = { TODO: "IN_PROGRESS", IN_PROGRESS: "DONE", DONE: null };

const form = document.getElementById("add-task-form");
const titleInput = document.getElementById("task-title");
const descInput = document.getElementById("task-description");
const errorBanner = document.getElementById("error-banner");

function showError(message) {
  errorBanner.textContent = message;
  errorBanner.classList.remove("hidden");
}

function clearError() {
  errorBanner.classList.add("hidden");
}

// Spring Data REST returns HAL+JSON: each task has its own resource URL under
// _links.self.href. We use that href directly for PATCH/DELETE rather than
// re-deriving /tasks/{id} ourselves, so this stays correct even if the
// underlying URL structure changes.
async function fetchTasks() {
  const res = await fetch("/api/tasks?size=200");
  if (!res.ok) throw new Error(`GET /api/tasks failed: ${res.status}`);
  const body = await res.json();
  return body._embedded ? body._embedded.tasks : [];
}

async function createTask(title, description) {
  const res = await fetch("/api/tasks", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ title, description, status: "TODO" }),
  });
  if (!res.ok) throw new Error(`POST /api/tasks failed: ${res.status}`);
}

async function updateTaskStatus(selfHref, newStatus) {
  const res = await fetch(selfHref, {
    method: "PATCH",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ status: newStatus }),
  });
  if (!res.ok) throw new Error(`PATCH task failed: ${res.status}`);
}

async function deleteTask(selfHref) {
  const res = await fetch(selfHref, { method: "DELETE" });
  if (!res.ok) throw new Error(`DELETE task failed: ${res.status}`);
}

function renderBoard(tasks) {
  STATUSES.forEach((status) => {
    const container = document.getElementById(`cards-${status}`);
    container.innerHTML = "";

    const tasksForColumn = tasks.filter((t) => (t.status || "TODO") === status);
    document.getElementById(`count-${status}`).textContent = tasksForColumn.length;

    if (tasksForColumn.length === 0) {
      const note = document.createElement("div");
      note.className = "empty-note";
      note.textContent = "No tasks here";
      container.appendChild(note);
      return;
    }

    tasksForColumn.forEach((task) => {
      const selfHref = task._links && task._links.self ? task._links.self.href : null;
      const card = document.createElement("div");
      card.className = "card";

      const titleEl = document.createElement("div");
      titleEl.className = "card-title";
      titleEl.textContent = task.title || "(untitled)";
      card.appendChild(titleEl);

      if (task.description) {
        const descEl = document.createElement("div");
        descEl.className = "card-desc";
        descEl.textContent = task.description;
        card.appendChild(descEl);
      }

      const actions = document.createElement("div");
      actions.className = "card-actions";

      const nextStatus = NEXT_STATUS[status];
      if (nextStatus && selfHref) {
        const advanceBtn = document.createElement("button");
        advanceBtn.className = "advance";
        advanceBtn.textContent = nextStatus === "DONE" ? "Mark done" : "Move forward";
        advanceBtn.onclick = () => handleAdvance(selfHref, nextStatus);
        actions.appendChild(advanceBtn);
      }

      if (selfHref) {
        const deleteBtn = document.createElement("button");
        deleteBtn.className = "delete";
        deleteBtn.textContent = "Delete";
        deleteBtn.onclick = () => handleDelete(selfHref);
        actions.appendChild(deleteBtn);
      }

      card.appendChild(actions);
      container.appendChild(card);
    });
  });
}

async function loadBoard() {
  try {
    const tasks = await fetchTasks();
    renderBoard(tasks);
    clearError();
  } catch (err) {
    showError("Could not load tasks from the API. Is the backend healthy?");
    console.error(err);
  }
}

async function handleAdvance(selfHref, newStatus) {
  try {
    await updateTaskStatus(selfHref, newStatus);
    await loadBoard();
  } catch (err) {
    showError("Could not update task status.");
    console.error(err);
  }
}

async function handleDelete(selfHref) {
  try {
    await deleteTask(selfHref);
    await loadBoard();
  } catch (err) {
    showError("Could not delete task.");
    console.error(err);
  }
}

form.addEventListener("submit", async (e) => {
  e.preventDefault();
  const title = titleInput.value.trim();
  const description = descInput.value.trim();
  if (!title) return;

  try {
    await createTask(title, description);
    titleInput.value = "";
    descInput.value = "";
    await loadBoard();
  } catch (err) {
    showError("Could not create task.");
    console.error(err);
  }
});

async function checkHealth() {
  const dot = document.getElementById("health-dot");
  const text = document.getElementById("health-text");
  try {
    const res = await fetch("/actuator/health");
    const body = await res.json();
    if (body.status === "UP") {
      dot.className = "health-dot up";
      text.textContent = "API healthy";
    } else {
      dot.className = "health-dot down";
      text.textContent = `API status: ${body.status}`;
    }
  } catch {
    dot.className = "health-dot down";
    text.textContent = "Could not reach /actuator/health";
  }
}

loadBoard();
checkHealth();
setInterval(loadBoard, 10000);