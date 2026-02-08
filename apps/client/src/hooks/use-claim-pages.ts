import { useState, useEffect } from "react";

export interface ClaimPage {
  id: string;
  title: string;
  subtitle: string;
  logo?: string;
  theme?: {
    primary?: string;
    background?: string;
  };
  streams: string[];
  createdAt: string;
  updatedAt: string;
}

export interface Stream {
  id: string;
  claimPageId: string;
  chain: "sepolia" | "sui";
  recipient: string;
  recipientName?: string;
  amount: string;
  asset: string;
  startDate: string;
  endDate: string;
  cliffDate?: string;
  status: "PENDING" | "ACTIVE" | "PAUSED" | "COMPLETED" | "CANCELLED";
  contractAddress?: string;
  txHash?: string;
  createdAt: string;
}

const STORAGE_KEY_PAGES = "xylkstream_claim_pages";
const STORAGE_KEY_STREAMS = "xylkstream_streams";

export function useClaimPages() {
  const [pages, setPages] = useState<Record<string, ClaimPage>>({});
  const [streams, setStreams] = useState<Record<string, Stream>>({});

  // Load from localStorage on mount
  useEffect(() => {
    const storedPages = localStorage.getItem(STORAGE_KEY_PAGES);
    const storedStreams = localStorage.getItem(STORAGE_KEY_STREAMS);

    if (storedPages) {
      try {
        setPages(JSON.parse(storedPages));
      } catch (e) {
        console.error("Failed to parse claim pages:", e);
      }
    }

    if (storedStreams) {
      try {
        setStreams(JSON.parse(storedStreams));
      } catch (e) {
        console.error("Failed to parse streams:", e);
      }
    }
  }, []);

  // Save to localStorage whenever data changes
  const savePages = (newPages: Record<string, ClaimPage>) => {
    setPages(newPages);
    localStorage.setItem(STORAGE_KEY_PAGES, JSON.stringify(newPages));
  };

  const saveStreams = (newStreams: Record<string, Stream>) => {
    setStreams(newStreams);
    localStorage.setItem(STORAGE_KEY_STREAMS, JSON.stringify(newStreams));
  };

  const createClaimPage = (data: Omit<ClaimPage, "id" | "createdAt" | "updatedAt" | "streams">) => {
    const id = `page-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
    const now = new Date().toISOString();
    const newPage: ClaimPage = {
      ...data,
      id,
      streams: [],
      createdAt: now,
      updatedAt: now,
    };

    savePages({ ...pages, [id]: newPage });
    return newPage;
  };

  const updateClaimPage = (id: string, data: Partial<ClaimPage>) => {
    if (!pages[id]) return null;

    const updatedPage = {
      ...pages[id],
      ...data,
      updatedAt: new Date().toISOString(),
    };

    savePages({ ...pages, [id]: updatedPage });
    return updatedPage;
  };

  const deleteClaimPage = (id: string) => {
    const { [id]: removed, ...rest } = pages;
    savePages(rest);

    // Also delete associated streams
    const updatedStreams = Object.fromEntries(
      Object.entries(streams).filter(([_, stream]) => stream.claimPageId !== id)
    );
    saveStreams(updatedStreams);
  };

  const createStream = (data: Omit<Stream, "id" | "createdAt">) => {
    const id = `stream-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
    const newStream: Stream = {
      ...data,
      id,
      createdAt: new Date().toISOString(),
    };

    saveStreams({ ...streams, [id]: newStream });

    // Add stream to claim page
    if (pages[data.claimPageId]) {
      updateClaimPage(data.claimPageId, {
        streams: [...pages[data.claimPageId].streams, id],
      });
    }

    return newStream;
  };

  const updateStream = (id: string, data: Partial<Stream>) => {
    if (!streams[id]) return null;

    const updatedStream = {
      ...streams[id],
      ...data,
    };

    saveStreams({ ...streams, [id]: updatedStream });
    return updatedStream;
  };

  const deleteStream = (id: string) => {
    const stream = streams[id];
    if (!stream) return;

    const { [id]: removed, ...rest } = streams;
    saveStreams(rest);

    // Remove from claim page
    if (pages[stream.claimPageId]) {
      updateClaimPage(stream.claimPageId, {
        streams: pages[stream.claimPageId].streams.filter((sid) => sid !== id),
      });
    }
  };

  const getClaimPage = (id: string) => pages[id] || null;

  const getStream = (id: string) => streams[id] || null;

  const getStreamsForPage = (pageId: string) => {
    return Object.values(streams).filter((stream) => stream.claimPageId === pageId);
  };

  return {
    pages: Object.values(pages),
    streams: Object.values(streams),
    createClaimPage,
    updateClaimPage,
    deleteClaimPage,
    createStream,
    updateStream,
    deleteStream,
    getClaimPage,
    getStream,
    getStreamsForPage,
  };
}
