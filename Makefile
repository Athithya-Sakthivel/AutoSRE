

clean:
	find . -type d -name "__pycache__" -exec rm -rf {} +
	find . -type d -name "dist" -exec rm -rf {} +
	find . -type f -name "*.pyc" -delete
	find . -type f -name "*.log" ! -path "./.git/*" -delete
	find . -type f -name "*.coverage" ! -path "./.git/*" -delete
	find . -type d -name ".mypy_cache" -exec rm -rf {} +
	find . -type d -name ".pytest_cache" -exec rm -rf {} +
	find . -type d -name ".ruff_cache" -exec rm -rf {} +
	rm -rf logs
	clear


tree:
	tree -a -I '.venv|node_modules|target|.ruff_cache|__pycache__|.git|.mypy_cache|.pytest_cache|dist|.repos'
