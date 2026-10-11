use std::num::NonZeroUsize;
use std::thread;

/// Runs `f` over `items` on scoped threads, each writing its own slots of
/// `out`. Returns the first error in input order.
///
/// Scoped threads: none outlives the call, so a process may fork right after
/// (a pool such as rayon's would leave its threads behind in the parent and
/// a broken pool in the child).
pub fn fill<'a, T, R, E>(
    items: &'a [T],
    out: &mut [R],
    f: impl Fn(&'a T) -> Result<R, E> + Sync,
) -> Result<(), E>
where
    T: Sync,
    R: Send,
    E: Send,
{
    let run = |items: &'a [T], out: &mut [R]| -> Result<(), E> {
        for (item, slot) in items.iter().zip(out) {
            *slot = f(item)?;
        }
        Ok(())
    };
    let run = &run;
    let threads = thread::available_parallelism().map_or(1, NonZeroUsize::get).min(items.len());
    if threads <= 1 {
        return run(items, out);
    }
    let chunk = items.len().div_ceil(threads);
    thread::scope(|scope| {
        let workers: Vec<_> = items
            .chunks(chunk)
            .zip(out.chunks_mut(chunk))
            .map(|(items, out)| scope.spawn(move || run(items, out)))
            .collect();
        // Chunks are in input order and each stops at its first error.
        workers.into_iter().try_for_each(|worker| {
            worker.join().unwrap_or_else(|panic| std::panic::resume_unwind(panic))
        })
    })
}
