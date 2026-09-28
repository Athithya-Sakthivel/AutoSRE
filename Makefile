

tree:
	tree -a -I '.venv|node_modules|target|.ruff_cache|__pycache__|.git|.mypy_cache|.pytest_cache|dist|.repos'

clean:
	find . -path "*/node_modules" -prune -o -type d -name "__pycache__" -exec rm -rf {} +
	find . -path "*/node_modules" -prune -o -type d -name "dist" -exec rm -rf {} +
	find . -path "*/node_modules" -prune -o -type f -name "*.pyc" -exec rm -f {} +
	find . -path "*/node_modules" -prune -o -type f -name "*.log" ! -path "./.git/*" -exec rm -f {} +
	find . -path "*/node_modules" -prune -o -type f -name "*.coverage" ! -path "./.git/*" -exec rm -f {} +
	find . -path "*/node_modules" -prune -o -type d -name ".mypy_cache" -exec rm -rf {} +
	find . -path "*/node_modules" -prune -o -type d -name ".pytest_cache" -exec rm -rf {} +
	find . -path "*/node_modules" -prune -o -type d -name ".ruff_cache" -exec rm -rf {} +
	rm -rf logs
	clear
