import type { ExtensionAPI } from '@oh-my-pi/pi-coding-agent';

/** Change only the TUI transport. Session, model, tools, jobs and process stay intact. */
export default function (pi: ExtensionAPI) {
  pi.registerCommand('native', {
    description: 'Native Tern frontend: on, off, or status; never restarts the agent',
    handler: async (args, ctx) => {
      const mode = args.trim() || 'status';
      if (mode !== 'on' && mode !== 'off' && mode !== 'status') {
        ctx.ui.notify('Usage: /native on|off|status', 'warning');
        return;
      }
      if (!ctx.hasUI || ctx.mode !== 'tui') {
        ctx.ui.notify('The native frontend requires interactive OMP.', 'error');
        return;
      }
      if (!ctx.isIdle() || ctx.hasPendingMessages()) {
        ctx.ui.notify('Wait until this agent and its message queue are idle before changing its frontend.', 'warning');
        return;
      }
      // The documented custom-component factory exposes the existing TUI. Finish
      // the component before stop/start, preserving the normal editor and focus.
      const tui = await ctx.ui.custom((tui, _theme, _keys, done) => {
        queueMicrotask(() => done(tui));
        return { render: () => ['Changing frontend…'], invalidate() {} };
      });
      if (mode === 'status') {
        ctx.ui.notify(`Frontend: ${tui.nativeRendering ? 'native TSP' : 'ANSI'}; PID ${process.pid}`, 'info');
        return;
      }
      if (!tui.terminal.onTspHello) {
        ctx.ui.notify('This OMP build does not expose native TSP negotiation.', 'error');
        return;
      }
      // Herdr is deliberately excluded from automatic probing by OMP; this
      // explicit user command opts in only after attaching a native transport.
      process.env.PI_TUI_NATIVE = mode === 'on' ? '1' : '0';
      tui.stop();
      tui.start();
      tui.requestRender(true);
      if (mode === 'off') {
        ctx.ui.notify(`Frontend: ANSI; same agent PID ${process.pid}`, 'info');
        return;
      }
      const { promise, resolve } = Promise.withResolvers<boolean>();
      const timeout = setTimeout(() => resolve(false), 2500);
      tui.terminal.onTspHello(hello => resolve(hello !== null));
      const confirmed = await promise;
      clearTimeout(timeout);
      if (confirmed && tui.nativeRendering) {
        ctx.ui.notify(`Frontend: native TSP; same agent PID ${process.pid}`, 'info');
      } else {
        ctx.ui.notify('No native frontend confirmed. Attach through Herdr’s native Tern transport, then run /native on again.', 'warning');
      }
    },
  });
}
