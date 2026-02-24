import { useState } from "react";
import {
  Box,
  Button,
  Heading,
  HStack,
  Input,
  Table,
  Thead,
  Tbody,
  Tr,
  Th,
  Td,
  Badge,
  IconButton,
  useDisclosure,
  Modal,
  ModalOverlay,
  ModalContent,
  ModalHeader,
  ModalBody,
  ModalFooter,
  FormControl,
  FormLabel,
  useToast,
  Select,
  InputGroup,
  InputRightElement,
  Tooltip,
} from "@chakra-ui/react";
import { QRCodeSVG } from "qrcode.react";
import {
  useUsersList,
  useCreateUser,
  useUpdateUser,
  useDeleteUser,
  useRegenerateSecret,
  useUserLinks,
  type User,
  type UserCreateInput,
  type UserUpdateInput,
} from "../api/users";

const PAGE_SIZE = 10;

function formatBytes(n: number): string {
  if (n === 0) return "0 B";
  const k = 1024;
  const i = Math.floor(Math.log(n) / Math.log(k));
  return `${(n / Math.pow(k, i)).toFixed(1)} ${["B", "KB", "MB", "GB", "TB"][i]}`;
}

export default function Users() {
  const [offset, setOffset] = useState(0);
  const [search, setSearch] = useState("");
  const [statusFilter, setStatusFilter] = useState<string>("");
  const { data, isLoading } = useUsersList({
    offset,
    limit: PAGE_SIZE,
    search: search || undefined,
    status: statusFilter || undefined,
  });
  const total = data?.total ?? 0;
  const users = data?.users ?? [];

  return (
    <Box>
      <Heading size="lg" mb={4}>
        Users
      </Heading>
      <HStack mb={4} gap={2} flexWrap="wrap">
        <Input
          placeholder="Search by username"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          maxW="xs"
        />
        <Select
          placeholder="Status"
          maxW="32"
          value={statusFilter}
          onChange={(e) => setStatusFilter(e.target.value)}
        >
          <option value="active">active</option>
          <option value="disabled">disabled</option>
          <option value="limited">limited</option>
          <option value="expired">expired</option>
        </Select>
        <CreateUserButton />
      </HStack>
      <Box bg="white" borderRadius="md" shadow="sm" overflowX="auto">
        <Table size="sm">
          <Thead>
            <Tr>
              <Th>Username</Th>
              <Th>Status</Th>
              <Th>Data used</Th>
              <Th>Data limit</Th>
              <Th>Expires</Th>
              <Th>Last seen</Th>
              <Th title="Currently connected unique IPs">Unique IPs</Th>
              <Th>Actions</Th>
            </Tr>
          </Thead>
          <Tbody>
            {isLoading
              ? null
              : users.map((u) => (
                  <UserRow key={u.id} user={u} onSearchChange={setSearch} />
                ))}
          </Tbody>
        </Table>
      </Box>
      {total > PAGE_SIZE && (
        <HStack mt={4} gap={2}>
          <Button
            size="sm"
            isDisabled={offset === 0}
            onClick={() => setOffset((o) => Math.max(0, o - PAGE_SIZE))}
          >
            Previous
          </Button>
          <span>
            {offset + 1}–{Math.min(offset + PAGE_SIZE, total)} of {total}
          </span>
          <Button
            size="sm"
            isDisabled={offset + PAGE_SIZE >= total}
            onClick={() => setOffset((o) => o + PAGE_SIZE)}
          >
            Next
          </Button>
        </HStack>
      )}
    </Box>
  );
}

function CreateUserButton() {
  const { isOpen, onOpen, onClose } = useDisclosure();
  const toast = useToast();
  const createUser = useCreateUser();
  const [form, setForm] = useState<UserCreateInput>({
    username: "",
    data_limit: null,
    max_connections: null,
    max_unique_ips: null,
    expire_at: null,
    note: null,
  });

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    createUser.mutate(form, {
      onSuccess: () => {
        toast({ title: "User created", status: "success" });
        onClose();
        setForm({ username: "", data_limit: null, max_connections: null, max_unique_ips: null, expire_at: null, note: null });
      },
      onError: (err: Error) => toast({ title: err.message, status: "error" }),
    });
  };

  return (
    <>
      <Button colorScheme="blue" size="sm" onClick={onOpen}>
        Create user
      </Button>
      <Modal isOpen={isOpen} onClose={onClose}>
        <ModalOverlay />
        <ModalContent>
          <form onSubmit={handleSubmit}>
            <ModalHeader>Create user</ModalHeader>
            <ModalBody>
              <UserFormFields create value={form} onChange={setForm} />
            </ModalBody>
            <ModalFooter>
              <Button variant="ghost" mr={3} onClick={onClose}>
                Cancel
              </Button>
              <Button type="submit" colorScheme="blue" isLoading={createUser.isPending}>
                Create
              </Button>
            </ModalFooter>
          </form>
        </ModalContent>
      </Modal>
    </>
  );
}

function UserFormFields({
  create,
  value,
  onChange,
}: {
  create: boolean;
  value: UserCreateInput | (UserUpdateInput & { username?: string });
  onChange: (v: UserCreateInput | UserUpdateInput) => void;
}) {
  const v = value as Record<string, unknown>;
  const update = (key: string, val: unknown) =>
    onChange({ ...value, [key]: val === "" ? null : val });
  return (
    <>
      {create && (
        <FormControl isRequired mb={3}>
          <FormLabel>Username</FormLabel>
          <Input
            pattern="[a-zA-Z0-9_]+"
            minLength={3}
            maxLength={32}
            value={(v.username as string) ?? ""}
            onChange={(e) => update("username", e.target.value)}
          />
        </FormControl>
      )}
      <FormControl mb={3}>
        <FormLabel>Data limit (bytes)</FormLabel>
        <Input
          type="number"
          min={0}
          value={v.data_limit ?? ""}
          onChange={(e) => update("data_limit", e.target.value ? Number(e.target.value) : null)}
        />
      </FormControl>
      <FormControl mb={3}>
        <FormLabel>Max connections</FormLabel>
        <Input
          type="number"
          min={0}
          value={v.max_connections ?? ""}
          onChange={(e) => update("max_connections", e.target.value ? Number(e.target.value) : null)}
        />
      </FormControl>
      <FormControl mb={3}>
        <Tooltip label="Maximum number of unique IPs that can be connected at the same time for this user; new connections from additional IPs are rejected until one disconnects." placement="top" hasArrow>
          <FormLabel cursor="help">Max unique IPs</FormLabel>
        </Tooltip>
        <Input
          type="number"
          min={0}
          value={v.max_unique_ips ?? ""}
          onChange={(e) => update("max_unique_ips", e.target.value ? Number(e.target.value) : null)}
        />
      </FormControl>
      <FormControl mb={3}>
        <FormLabel>Expire at (ISO datetime)</FormLabel>
        <Input
          type="datetime-local"
          value={v.expire_at ? (v.expire_at as string).slice(0, 16) : ""}
          onChange={(e) => update("expire_at", e.target.value ? new Date(e.target.value).toISOString() : null)}
        />
      </FormControl>
      {"status" in value && value.status !== undefined && (
        <FormControl mb={3}>
          <FormLabel>Status</FormLabel>
          <Select
            value={(value as UserUpdateInput).status ?? ""}
            onChange={(e) => update("status", e.target.value || null)}
          >
            <option value="active">active</option>
            <option value="disabled">disabled</option>
            <option value="limited">limited</option>
            <option value="expired">expired</option>
          </Select>
        </FormControl>
      )}
      <FormControl>
        <FormLabel>Note</FormLabel>
        <Input
          value={(v.note as string) ?? ""}
          onChange={(e) => update("note", e.target.value || null)}
        />
      </FormControl>
    </>
  );
}

function UserRow({
  user,
  onSearchChange,
}: {
  user: User;
  onSearchChange: (s: string) => void;
}) {
  const [linksModalUser, setLinksModalUser] = useState<string | null>(null);
  const [editUser, setEditUser] = useState<User | null>(null);
  const [deleteUser, setDeleteUser] = useState<User | null>(null);
  const toast = useToast();
  const updateUser = useUpdateUser();
  const deleteUserMutation = useDeleteUser();
  const regenerateSecret = useRegenerateSecret();

  const handleCopy = async (text: string) => {
    try {
      await navigator.clipboard.writeText(text);
      toast({ title: "Copied to clipboard", status: "success", duration: 1500 });
    } catch {
      toast({ title: "Copy failed", status: "error", duration: 2000 });
    }
  };

  return (
    <>
      <Tr>
        <Td fontWeight="medium">{user.username}</Td>
        <Td>
          <Badge colorScheme={user.status === "active" ? "green" : "gray"}>
            {user.status}
          </Badge>
        </Td>
        <Td>{formatBytes(user.data_used)}</Td>
        <Td>{user.data_limit != null ? formatBytes(user.data_limit) : "—"}</Td>
        <Td>{user.expire_at ? new Date(user.expire_at).toLocaleString() : "—"}</Td>
        <Td>{user.last_seen_at ? new Date(user.last_seen_at).toLocaleString(undefined, { dateStyle: "short", timeStyle: "short" }) : "—"}</Td>
        <Td>{user.active_unique_ips != null ? String(user.active_unique_ips) : "—"}</Td>
        <Td>
          <HStack gap={1}>
            <Button
              size="xs"
              variant="outline"
              onClick={() => setLinksModalUser(user.username)}
            >
              Link / QR
            </Button>
            <Button
              size="xs"
              variant="outline"
              onClick={() => setEditUser(user)}
            >
              Edit
            </Button>
            <Button
              size="xs"
              variant="outline"
              colorScheme="orange"
              onClick={() => regenerateSecret.mutate(user.username, {
                onSuccess: () => toast({ title: "Secret regenerated", status: "success" }),
                onError: (e: Error) => toast({ title: e.message, status: "error" }),
              })}
            >
              Regenerate
            </Button>
            <Button
              size="xs"
              variant="outline"
              colorScheme="red"
              onClick={() => setDeleteUser(user)}
            >
              Delete
            </Button>
          </HStack>
        </Td>
      </Tr>
      {linksModalUser && (
        <LinksModal
          username={linksModalUser}
          onClose={() => setLinksModalUser(null)}
          onCopy={handleCopy}
        />
      )}
      {editUser && (
        <EditUserModal
          user={editUser}
          onClose={() => setEditUser(null)}
          onSave={(body) => {
            updateUser.mutate({ username: editUser.username, ...body }, {
              onSuccess: () => {
                toast({ title: "User updated", status: "success" });
                setEditUser(null);
              },
              onError: (e: Error) => toast({ title: e.message, status: "error" }),
            });
          }}
          isLoading={updateUser.isPending}
        />
      )}
      {deleteUser && (
        <DeleteConfirmModal
          username={deleteUser.username}
          onClose={() => setDeleteUser(null)}
          onConfirm={() => {
            deleteUserMutation.mutate(deleteUser.username, {
              onSuccess: () => {
                toast({ title: "User deleted", status: "success" });
                setDeleteUser(null);
              },
              onError: (e: Error) => toast({ title: e.message, status: "error" }),
            });
          }}
          isLoading={deleteUserMutation.isPending}
        />
      )}
    </>
  );
}

function LinksModal({
  username,
  onClose,
  onCopy,
}: {
  username: string;
  onClose: () => void;
  onCopy: (t: string) => void;
}) {
  const { data: links, isLoading } = useUserLinks(username);
  const tg = links?.tg_link ?? "";
  const https = links?.https_link ?? "";

  return (
    <Modal isOpen onClose={onClose} size="md">
      <ModalOverlay />
      <ModalContent>
        <ModalHeader>Proxy links — {username}</ModalHeader>
        <ModalBody>
          {isLoading ? (
            <p>Loading…</p>
          ) : (
            <>
              <FormControl mb={3}>
                <FormLabel>tg:// link</FormLabel>
                <InputGroup>
                  <Input value={tg} readOnly pr="5rem" />
                  <InputRightElement width="4rem">
                    <Button size="sm" onClick={() => onCopy(tg)}>
                      Copy
                    </Button>
                  </InputRightElement>
                </InputGroup>
              </FormControl>
              <FormControl mb={3}>
                <FormLabel>https://t.me link</FormLabel>
                <InputGroup>
                  <Input value={https} readOnly pr="5rem" />
                  <InputRightElement width="4rem">
                    <Button size="sm" onClick={() => onCopy(https)}>
                      Copy
                    </Button>
                  </InputRightElement>
                </InputGroup>
              </FormControl>
              <Box mt={4} p={4} bg="gray.50" borderRadius="md" display="inline-block">
                <QRCodeSVG value={tg || " "} size={180} level="M" />
              </Box>
            </>
          )}
        </ModalBody>
        <ModalFooter>
          <Button onClick={onClose}>Close</Button>
        </ModalFooter>
      </ModalContent>
    </Modal>
  );
}

function EditUserModal({
  user,
  onClose,
  onSave,
  isLoading,
}: {
  user: User;
  onClose: () => void;
  onSave: (body: UserUpdateInput) => void;
  isLoading: boolean;
}) {
  const [form, setForm] = useState<UserUpdateInput>({
    data_limit: user.data_limit,
    max_connections: user.max_connections,
    max_unique_ips: user.max_unique_ips,
    expire_at: user.expire_at,
    status: user.status,
    note: user.note,
  });

  return (
    <Modal isOpen onClose={onClose}>
      <ModalOverlay />
      <ModalContent>
        <form
          onSubmit={(e) => {
            e.preventDefault();
            onSave(form);
          }}
        >
          <ModalHeader>Edit {user.username}</ModalHeader>
          <ModalBody>
            <UserFormFields create={false} value={form} onChange={setForm} />
          </ModalBody>
          <ModalFooter>
            <Button variant="ghost" mr={3} onClick={onClose}>
              Cancel
            </Button>
            <Button type="submit" colorScheme="blue" isLoading={isLoading}>
              Save
            </Button>
          </ModalFooter>
        </form>
      </ModalContent>
    </Modal>
  );
}

function DeleteConfirmModal({
  username,
  onClose,
  onConfirm,
  isLoading,
}: {
  username: string;
  onClose: () => void;
  onConfirm: () => void;
  isLoading: boolean;
}) {
  return (
    <Modal isOpen onClose={onClose}>
      <ModalOverlay />
      <ModalContent>
        <ModalHeader>Delete user</ModalHeader>
        <ModalBody>Delete user &quot;{username}&quot;? This cannot be undone.</ModalBody>
        <ModalFooter>
          <Button variant="ghost" mr={3} onClick={onClose}>
            Cancel
          </Button>
          <Button colorScheme="red" onClick={onConfirm} isLoading={isLoading}>
            Delete
          </Button>
        </ModalFooter>
      </ModalContent>
    </Modal>
  );
}
