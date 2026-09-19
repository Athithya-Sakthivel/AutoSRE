import { isRouteErrorResponse, Link, useRouteError } from "react-router";

export function RouterErrorElement() {
  const error = useRouteError();

  let title = "Application Error";
  let message = "The requested page could not be rendered.";

  if (isRouteErrorResponse(error)) {
    title = `${error.status} ${error.statusText}`;
    message =
      typeof error.data === "string"
        ? error.data
        : "The requested page could not be rendered.";
  } else if (error instanceof Error) {
    message = error.message;
  }

  return (
    <main className="error-page">
      <div className="card error-card">
        <div className="card-body">
          <p className="eyebrow">Rivulet</p>
          <h1 className="page-title">{title}</h1>
          <p className="page-subtitle">{message}</p>
          <div className="error-actions">
            <Link className="button button-primary" to="/">
              Return to Checkout
            </Link>
          </div>
        </div>
      </div>
    </main>
  );
}
