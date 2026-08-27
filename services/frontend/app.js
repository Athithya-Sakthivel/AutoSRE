const API_BASE = '/api/v1';

let token = localStorage.getItem('token');

const authSection = document.getElementById('auth-section');
const taskSection = document.getElementById('task-section');
const authStatus = document.getElementById('auth-status');
const taskList = document.getElementById('task-list');

async function api(path, method = 'GET', body = null) {
    const headers = { 'Content-Type': 'application/json' };
    if (token) headers['Authorization'] = `Bearer ${token}`;

    const response = await fetch(`${API_BASE}${path}`, {
        method,
        headers,
        body: body ? JSON.stringify(body) : null
    });

    if (!response.ok) {
        const error = await response.json().catch(() => ({ message: 'Unknown error' }));
        throw new Error(error.message || response.statusText);
    }
    return response.status === 204 ? null : response.json();
}

async function login() {
    const username = document.getElementById('username').value;
    const password = document.getElementById('password').value;
    try {
        const data = await api('/auth/login', 'POST', { username, password });
        token = data.token;
        localStorage.setItem('token', token);
        authStatus.textContent = 'Logged in';
        showTasks();
    } catch (e) {
        authStatus.textContent = e.message;
    }
}

async function register() {
    const username = document.getElementById('username').value;
    const password = document.getElementById('password').value;
    try {
        const data = await api('/auth/register', 'POST', {
            username,
            email: `${username}@example.com`,
            password
        });
        token = data.token;
        localStorage.setItem('token', token);
        authStatus.textContent = 'Registered & logged in';
        showTasks();
    } catch (e) {
        authStatus.textContent = e.message;
    }
}

async function createTask() {
    const title = document.getElementById('task-title').value;
    const description = document.getElementById('task-desc').value;
    try {
        await api('/tasks', 'POST', { title, description, status: 'PENDING' });
        document.getElementById('task-title').value = '';
        document.getElementById('task-desc').value = '';
        showTasks();
    } catch (e) {
        alert(e.message);
    }
}

async function showTasks() {
    try {
        const tasks = await api('/tasks');
        taskList.innerHTML = '';
        tasks.forEach(task => {
            const li = document.createElement('li');
            li.innerHTML = `<span>${task.title} (${task.status})</span><span>${new Date(task.createdAt).toLocaleString()}</span>`;
            taskList.appendChild(li);
        });
        taskSection.hidden = false;
    } catch (e) {
        authStatus.textContent = e.message;
    }
}

document.getElementById('login-btn').addEventListener('click', login);
document.getElementById('register-btn').addEventListener('click', register);
document.getElementById('create-task-btn').addEventListener('click', createTask);

if (token) showTasks();