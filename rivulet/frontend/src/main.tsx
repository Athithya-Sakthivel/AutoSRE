import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { createBrowserRouter } from "react-router";
import { RouterProvider } from "react-router/dom";
import { App } from "./App";
import { CheckoutPage } from "./pages/Checkout";
import { InventoryPage } from "./pages/Inventory";
import { OrdersPage } from "./pages/Orders";
import { RouterErrorElement } from "./components/RouterErrorElement";
import { initTelemetry } from "./telemetry";
import "./styles.css";

// Register OTel before React mounts so fetch and user-interaction
// instrumentation are installed before application activity starts.
initTelemetry();

const router = createBrowserRouter([
  {
    path: "/",
    Component: App,
    errorElement: <RouterErrorElement />,
    children: [
      { index: true, Component: CheckoutPage },
      { path: "inventory", Component: InventoryPage },
      { path: "orders", Component: OrdersPage },
    ],
  },
]);

const rootElement = document.getElementById("root");

if (!rootElement) {
  throw new Error("Root element not found");
}

createRoot(rootElement).render(
  <StrictMode>
    <RouterProvider router={router} />
  </StrictMode>,
);
