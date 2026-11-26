import { useEffect, useRef, useState, useSyncExternalStore, type FormEvent, type ReactNode } from "react";
import { AnimatePresence, motion } from "motion/react";
import type { TerminalEdit, TerminalModel } from "./terminalModel";
import { TAB_COLORS, type TabColor } from "./workspace";

/** Rename / startup command / group dialogs, shown over the window. */
export function TerminalDialogs({ model }: { model: TerminalModel }) {
  const { editing } = useSyncExternalStore(model.subscribe, model.getSnapshot);
  const close = () => {
    model.edit(undefined);
    const id = model.workspace.selectedTabID;
    if (id) requestAnimationFrame(() => model.existingSession(id)?.focus());
  };

  return (
    <AnimatePresence>
      {editing && (
        <motion.div
          className="scrim"
          initial={{ opacity: 0 }}
          animate={{ opacity: 1 }}
          exit={{ opacity: 0 }}
          transition={{ duration: 0.15 }}
          onMouseDown={(e) => e.target === e.currentTarget && close()}
        >
          <motion.div
            className="dialog"
            initial={{ opacity: 0, scale: 0.96, y: 8 }}
            animate={{ opacity: 1, scale: 1, y: 0 }}
            exit={{ opacity: 0, scale: 0.97 }}
            transition={{ type: "spring", stiffness: 420, damping: 32 }}
          >
            <DialogBody key={JSON.stringify(editing)} model={model} edit={editing} close={close} />
          </motion.div>
        </motion.div>
      )}
    </AnimatePresence>
  );
}

function DialogBody({ model, edit, close }: { model: TerminalModel; edit: TerminalEdit; close: () => void }) {
  switch (edit.kind) {
    case "renameTab": {
      const tab = model.tab(edit.id);
      return (
        <TextDialog
          title="Rename Tab"
          label="Name"
          placeholder={tab ? model.title({ ...tab, name: undefined }) : ""}
          help="Leave empty to show the folder name."
          initial={tab?.name ?? ""}
          submit={(v) => model.rename(edit.id, v)}
          close={close}
        />
      );
    }
    case "startupCommand":
      return (
        <TextDialog
          title="Startup Command"
          label="Command"
          placeholder="pnpm dev"
          help="Runs every time this tab's shell starts — when Clearspace opens, after a restart, or when you restart the shell."
          initial={model.tab(edit.id)?.startupCommand ?? ""}
          monospace
          submit={(v) => model.setStartupCommand(edit.id, v)}
          close={close}
        />
      );
    case "renameGroup":
      return (
        <TextDialog
          title="Rename Group"
          label="Name"
          initial={model.group(edit.id)?.name ?? ""}
          submit={(v) => model.renameGroup(edit.id, v)}
          close={close}
        />
      );
    case "newGroup":
      return <NewGroupDialog model={model} movingTab={edit.movingTab} close={close} />;
  }
}

function TextDialog(props: {
  title: string;
  label: string;
  initial: string;
  placeholder?: string;
  help?: string;
  monospace?: boolean;
  submit: (value: string) => void;
  close: () => void;
}) {
  const [value, setValue] = useState(props.initial);
  return (
    <Form
      title={props.title}
      onSubmit={() => {
        props.submit(value);
        props.close();
      }}
      close={props.close}
    >
      <label className="field">
        <span>{props.label}</span>
        <AutoFocusInput
          value={value}
          placeholder={props.placeholder}
          className={props.monospace ? "mono" : undefined}
          onChange={setValue}
        />
      </label>
      {props.help && <p className="help">{props.help}</p>}
    </Form>
  );
}

function NewGroupDialog({ model, movingTab, close }: { model: TerminalModel; movingTab?: string; close: () => void }) {
  const [name, setName] = useState("");
  const [color, setColor] = useState<TabColor>(TAB_COLORS[(model.workspace.groups.length + 6) % TAB_COLORS.length]);
  return (
    <Form
      title="New Group"
      onSubmit={() => {
        model.newGroup(name, color, movingTab);
        close();
      }}
      close={close}
      submitLabel="Create"
    >
      <label className="field">
        <span>Name</span>
        <AutoFocusInput value={name} placeholder={`Group ${model.workspace.groups.length + 1}`} onChange={setName} />
      </label>
      <div className="field">
        <span>Color</span>
        <div className="swatches">
          {TAB_COLORS.map((c) => (
            <button
              type="button"
              key={c}
              className={"swatch" + (c === color ? " selected" : "")}
              style={{ ["--dot" as string]: `var(--c-${c})` }}
              title={c}
              onClick={() => setColor(c)}
            />
          ))}
        </div>
      </div>
      <p className="help">{movingTab ? "The tab moves into the new group." : "A new tab opens in the group."}</p>
    </Form>
  );
}

function Form({
  title,
  children,
  onSubmit,
  close,
  submitLabel = "Save",
}: {
  title: string;
  children: ReactNode;
  onSubmit: () => void;
  close: () => void;
  submitLabel?: string;
}) {
  return (
    <form
      onSubmit={(e: FormEvent) => {
        e.preventDefault();
        onSubmit();
      }}
      onKeyDown={(e) => e.key === "Escape" && close()}
    >
      <h2>{title}</h2>
      {children}
      <div className="dialog-buttons">
        <button type="button" className="plain-button" onClick={close}>
          Cancel
        </button>
        <button type="submit" className="primary-button">
          {submitLabel}
        </button>
      </div>
    </form>
  );
}

function AutoFocusInput({
  value,
  onChange,
  placeholder,
  className,
}: {
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
  className?: string;
}) {
  const ref = useRef<HTMLInputElement>(null);
  useEffect(() => {
    ref.current?.focus();
    ref.current?.select();
  }, []);
  return (
    <input
      ref={ref}
      value={value}
      placeholder={placeholder}
      className={className}
      spellCheck={false}
      autoCorrect="off"
      autoCapitalize="off"
      onChange={(e) => onChange(e.target.value)}
    />
  );
}
